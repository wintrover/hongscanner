import 'package:flutter/material.dart';

import '../api/api_models.dart';
import 'app_scope.dart';
import 'widgets.dart';

/// Digest/summary cover list route: every event the notification
/// covered, one row per recorded fact, fetched with the same
/// `GET /events/{id}` path as the detail route. Pushed onto the root
/// navigator by notification taps (store.openEvent with a cover list);
/// a row tap routes to the existing event detail. The ③ contract: a
/// digest tap gives the operator access to *all* covered events, not
/// just the representative one.
///
/// Honest by construction: loading is a real fetch in flight, a
/// failure (offline, refused, unknown id) is a visible error card with
/// a retry — a partial list is never dressed as complete — and rows
/// render exactly what the facts recorded.
class DigestListScreen extends StatelessWidget {
  const DigestListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('다이제스트 사건 목록')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            sectionBody<List<EventDetailResponse>>(
              context,
              store.digestEvents,
              loaded: (context, details) => _DigestBody(details: details),
              emptyMessage: '다이제스트 기록 없음',
              onRetry: store.refreshDigest,
            ),
          ],
        ),
      ),
    );
  }
}

class _DigestBody extends StatelessWidget {
  const _DigestBody({required this.details});

  final List<EventDetailResponse> details;

  @override
  Widget build(BuildContext context) {
    if (details.isEmpty) return const SectionEmpty(message: '다이제스트 기록 없음');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            for (final detail in details) _DigestRow(event: detail.event),
          ],
        ),
      ),
    );
  }
}

class _DigestRow extends StatelessWidget {
  const _DigestRow({required this.event});

  final ApiEvent event;

  @override
  Widget build(BuildContext context) {
    final direction = event.direction;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        switch (direction) {
          'UP' => Icons.trending_up,
          'DOWN' => Icons.trending_down,
          _ => Icons.circle_outlined,
        },
        color: switch (direction) {
          'UP' => Colors.red,
          'DOWN' => Colors.blue,
          _ => null,
        },
      ),
      title: Text(_rowTitle(event)),
      subtitle: Text(event.observedAt ?? '?'),
      trailing: const Icon(Icons.chevron_right),
      onTap: event.eventId == null
          ? null
          : () => AppScope.of(context).openEvent(event.eventId!),
    );
  }
}

/// Row title: the fact's own name (the vendor row preserved by the
/// input boundary), falling back to the symbol — the same policy as
/// the market-view rows. Direction rides verbatim, like the history
/// rows.
String _rowTitle(ApiEvent event) {
  final name = event.name ?? event.symbol;
  final base = name ?? _shortId(event.eventId);
  final direction = event.direction;
  final label = _rankChangeLabel(event);
  return direction == null ? '$base · $label' : '$base · $direction · $label';
}

String _shortId(String? eventId) {
  final id = eventId;
  if (id == null) return '?';
  return id.length <= 12 ? id : id.substring(0, 12);
}

/// Rank-change label: 진입/이탈 for the TOP10 in/out transitions, the
/// recorded previous→new ranks for RANK_CHANGED (a missing previous
/// rank shows the new rank alone — no prior state, never a fake 0; a
/// missing rank stays '?'). Anything outside the market-alert cover
/// vocabulary is shown verbatim — a fact is never relabeled.
String _rankChangeLabel(ApiEvent event) {
  switch (event.eventType) {
    case 'TOP10_ENTERED':
      return '진입';
    case 'TOP10_EXITED':
      return '이탈';
    case 'RANK_CHANGED':
      final rank = event.rank;
      if (rank == null) return '?';
      final previousRank = event.previousRank;
      return previousRank == null ? '$rank위' : '$previousRank위 → $rank위';
  }
  return event.eventType ?? '?';
}
