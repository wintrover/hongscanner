import 'package:flutter/material.dart';

import '../api/api_models.dart';
import 'app_scope.dart';
import 'widgets.dart';

/// Event detail route: the selected event's recorded fact, verbatim, plus
/// its delivery records kept in their own section. Pushed onto the root
/// navigator by list selections and notification taps (store.openEvent);
/// the app bar's back button (or the system back gesture) pops it and
/// returns to the tab shell. The evidence reference is what the judgment
/// consumed — the fact's 근거.
class EventDetailScreen extends StatelessWidget {
  const EventDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    final eventId = store.selectedEventId;
    return Scaffold(
      appBar: AppBar(title: const Text('이벤트 상세')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (eventId == null)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.touch_app_outlined),
                  title: Text('이벤트 미선택'),
                  subtitle: Text(
                      '후보·히스토리 목록이나 알림 탭으로 이벤트를 선택하면 기록된 사실이 표시됩니다.'),
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      eventId,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                  IconButton(
                    tooltip: '다시 조회',
                    onPressed: () => store.openEvent(eventId),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              sectionBody<EventDetailResponse>(
                context,
                store.eventDetail,
                loaded: (context, detail) => _DetailBody(detail: detail),
                emptyMessage: '기록 없음',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.detail});

  final EventDetailResponse detail;

  @override
  Widget build(BuildContext context) {
    final event = detail.event;
    final evidence = event.evidenceRef;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (evidence != null)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('근거 (evidence_ref)',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  SelectableText(evidence,
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(fontFamily: 'monospace')),
                ],
              ),
            ),
          ),
        const SectionTitle('기록된 사실', subtitle: 'ledger 팩트 원문 (키 코드포인트 순)'),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FactRows(
              rows: [
                for (final entry in event.sortedFields)
                  (entry.key, entry.value == null ? 'null' : '${entry.value}'),
              ],
            ),
          ),
        ),
        const SectionTitle('전달 기록',
            subtitle: 'delivery ledger — 운영 상태 (팩트에 병합되지 않음)'),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: detail.delivery.isEmpty
                ? const SectionEmpty(message: '전달 기록 없음')
                : Column(
                    children: [
                      for (final record in detail.delivery)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            switch (record.state) {
                              'ACCEPTED' => Icons.check_circle_outline,
                              'FAILED' => Icons.error_outline,
                              'PENDING' => Icons.schedule,
                              _ => Icons.help_outline,
                            },
                          ),
                          title: Text(
                              '${record.deviceId ?? '?'} — ${record.state ?? '?'}'),
                          subtitle: Text(
                            'attempts ${record.attempts ?? '?'} · '
                            '${record.updatedAt ?? '?'}'
                            '${record.providerMessageId == null ? '' : '\n${record.providerMessageId}'}',
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}
