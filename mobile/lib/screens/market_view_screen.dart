import 'package:flutter/material.dart';

import '../api/api_models.dart';
import '../state/app_store.dart';
import '../services/push_permission.dart';
import 'app_scope.dart';
import 'widgets.dart';

/// Market view tab: the single server projection (`GET
/// /mobile/market-view`) rendered as exactly three market elements —
/// 상승 TOP 10, 하락 TOP 10, 최근 후보 이벤트 (≤100) — plus the run/as_of
/// header and the by-data-quality status. The app never recomputes ranks
/// or filters events into candidates: the server projection is
/// authoritative and this screen is a read-only display of it.
class MarketViewScreen extends StatelessWidget {
  const MarketViewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: store.resync,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: [
            Text('Market View',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 12),
            _PushCard(store: store),
            sectionBody<MarketViewResponse>(
              context,
              store.marketView,
              loaded: (context, marketView) =>
                  _MarketViewBody(marketView: marketView),
              onRetry: store.resync,
            ),
          ],
        ),
      ),
    );
  }
}

class _MarketViewBody extends StatelessWidget {
  const _MarketViewBody({required this.marketView});

  final MarketViewResponse marketView;

  @override
  Widget build(BuildContext context) {
    final run = marketView.run;
    final byDataQuality = marketView.status?.byDataQuality;
    final byDataQualityText = byDataQuality == null || byDataQuality.isEmpty
        ? '기록 없음'
        : byDataQuality.entries
            .map((e) => '${e.key}×${e.value}')
            .join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('세션 · 시점',
            subtitle: '/mobile/market-view — 프로젝션 기준 (서버가 정함)'),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FactRows(rows: [
              ('session_date', run?.sessionDate ?? '기록 없음'),
              ('as_of', marketView.asOf ?? '기록 없음'),
              ('데이터 품질', byDataQualityText),
            ]),
          ),
        ),
        const SectionTitle('상승 TOP 10',
            subtitle: 'rising_top10 — 서버 프로젝션 (rank 오름차순)'),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _Top10List(
              items: marketView.risingTop10,
              direction: 'UP',
              emptyMessage: '상승 TOP 10 기록 없음',
            ),
          ),
        ),
        const SectionTitle('하락 TOP 10',
            subtitle: 'falling_top10 — 서버 프로젝션 (rank 오름차순)'),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _Top10List(
              items: marketView.fallingTop10,
              direction: 'DOWN',
              emptyMessage: '하락 TOP 10 기록 없음',
            ),
          ),
        ),
        const SectionTitle('최근 후보 이벤트',
            subtitle: 'history — 보관된 후보 이벤트 (최대 100건, 오래된→최신)'),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _HistoryList(
              items: marketView.history,
              emptyMessage: '후보 이벤트 기록 없음',
            ),
          ),
        ),
      ],
    );
  }
}

class _Top10List extends StatelessWidget {
  const _Top10List({
    required this.items,
    required this.direction,
    required this.emptyMessage,
  });

  final List<MarketViewItem> items;
  final String direction;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return SectionEmpty(message: emptyMessage);
    return Column(
      children: [
        for (final item in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              direction == 'UP' ? Icons.trending_up : Icons.trending_down,
              color: direction == 'UP' ? Colors.red : Colors.blue,
            ),
            title: Text(
              item.symbol == null
                  ? (item.eventId ?? '?').substring(0, 12)
                  : '${item.symbol} (rank ${item.rank ?? '—'})',
            ),
            subtitle: Text(
                '${item.observedAt ?? '?'} · ${item.dataQuality ?? '?'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: item.eventId == null
                ? null
                : () => AppScope.of(context).openEvent(item.eventId!),
          ),
      ],
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.items, required this.emptyMessage});

  final List<MarketViewItem> items;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return SectionEmpty(message: emptyMessage);
    return Column(
      children: [
        for (final item in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(
              switch (item.direction) {
                'UP' => Icons.trending_up,
                'DOWN' => Icons.trending_down,
                _ => Icons.circle_outlined,
              },
              color: switch (item.direction) {
                'UP' => Colors.red,
                'DOWN' => Colors.blue,
                _ => null,
              },
            ),
            title: Text(
              '${item.eventType ?? '?'}'
              '${item.symbol == null ? '' : ' · ${item.symbol}'}'
              '${item.direction == null ? '' : ' · ${item.direction}'}'
              // rank is absent on CANDIDATE_EXITED — honest absence,
              // never a fake 0.
              '${item.rank == null ? '' : ' #${item.rank}'}',
            ),
            subtitle: Text(
                '${item.observedAt ?? '?'} · ${item.dataQuality ?? '?'}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: item.eventId == null
                ? null
                : () => AppScope.of(context).openEvent(item.eventId!),
          ),
      ],
    );
  }
}

class _PushCard extends StatelessWidget {
  const _PushCard({required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    final push = store.pushState;
    final (icon, label) = switch (push.phase) {
      PushPhase.unwired => (
          Icons.notifications_off_outlined,
          '푸시 미연결 — Firebase 미설정 (mobile/README.md handoff 참조)'
        ),
      PushPhase.notAsked => (Icons.notifications_active_outlined, '권한 요청 준비'),
      PushPhase.asking => (Icons.hourglass_top, '권한 요청 중…'),
      PushPhase.granted => (Icons.notifications_active, '푸시 허용됨'),
      PushPhase.denied => (Icons.notifications_off, '푸시 비활성 — 권한 거부됨'),
      PushPhase.provisional => (Icons.notifications_paused, '프로비저널 허용'),
      PushPhase.unknown => (Icons.help_outline, '권한 상태 미확정 — 마지막 요청의 응답이 기록되지 않음'),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text(label)),
                if (push.phase == PushPhase.denied ||
                    push.phase == PushPhase.unknown)
                  TextButton(
                    onPressed: store.requestPushPermission,
                    child: const Text('다시 요청'),
                  ),
              ],
            ),
            if (push.askedCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '요청 이력: ${push.askedCount}회'
                  '${push.lastAskedAt == null ? '' : ' · 마지막 ${push.lastAskedAt!.toIso8601String()}'}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor),
                ),
              ),
            _TokenArea(push: push),
          ],
        ),
      ),
    );
  }
}

class _TokenArea extends StatelessWidget {
  const _TokenArea({required this.push});

  final PushUiState push;

  @override
  Widget build(BuildContext context) {
    final token = push.token;
    final problem = push.tokenError ?? push.notice;
    if (token == null && problem == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('FCM 토큰 (운영자가 tools/notify/register로 서버에 등록)',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          if (token != null)
            SelectableText(
              // Full value, never truncated: the operator copies exactly
              // this identifier into tools/notify/notify_register.py.
              token,
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            Text(problem ?? '',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.error)),
        ],
      ),
    );
  }
}
