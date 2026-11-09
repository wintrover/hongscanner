import 'package:flutter/material.dart';

import '../api/api_models.dart';
import 'app_scope.dart';
import 'widgets.dart';

/// 후보 tab: the rising/falling top 10 cards of the single server
/// projection (`GET /mobile/market-view`). The app never recomputes ranks
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
            sectionBody<MarketViewResponse>(
              context,
              store.marketView,
              loaded: (context, marketView) =>
                  _Top10sBody(marketView: marketView),
              onRetry: store.resync,
            ),
          ],
        ),
      ),
    );
  }
}

/// 히스토리 tab: the retained candidate-event tail (≤100, server order:
/// oldest→newest, CANDIDATE_* only). Same single projection as the 후보
/// tab — a tab switch reads the store, it never refetches.
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

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
            sectionBody<MarketViewResponse>(
              context,
              store.marketView,
              loaded: (context, marketView) =>
                  _HistoryBody(marketView: marketView),
              onRetry: store.resync,
            ),
          ],
        ),
      ),
    );
  }
}

class _Top10sBody extends StatelessWidget {
  const _Top10sBody({required this.marketView});

  final MarketViewResponse marketView;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
      ],
    );
  }
}

class _HistoryBody extends StatelessWidget {
  const _HistoryBody({required this.marketView});

  final MarketViewResponse marketView;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _HistoryList(
          items: marketView.history,
          emptyMessage: '후보 이벤트 기록 없음',
        ),
      ),
    );
  }
}

/// Row title: the recorded stock name, falling back to the symbol when
/// the ledger carries no name record.
String _itemTitle(MarketViewItem item) =>
    item.name ?? item.symbol ?? (item.eventId ?? '?').substring(0, 12);

/// Row subtitle policy: a normal-quality row (the server's normal set:
/// OK / COMPLETE / OBSERVING) shows just the observation time; anything
/// else — INCOMPLETE, UNKNOWN, null, unrecognized — keeps the explicit
/// quality suffix so incompleteness is never disguised as normal.
String _qualityAwareSubtitle(MarketViewItem item) {
  const normalQualities = {'OK', 'COMPLETE', 'OBSERVING'};
  final quality = item.dataQuality;
  if (quality != null && normalQualities.contains(quality)) {
    return item.observedAt ?? '?';
  }
  return '${item.observedAt ?? '?'} · ${quality ?? '?'}';
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
            title: Text('${_itemTitle(item)} (rank ${item.rank ?? '—'})'),
            subtitle: Text(_qualityAwareSubtitle(item)),
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
              '${item.eventType ?? '?'} · ${_itemTitle(item)}'
              '${item.direction == null ? '' : ' · ${item.direction}'}'
              // rank is absent on CANDIDATE_EXITED — honest absence,
              // never a fake 0.
              '${item.rank == null ? '' : ' #${item.rank}'}',
            ),
            subtitle: Text(_qualityAwareSubtitle(item)),
            trailing: const Icon(Icons.chevron_right),
            onTap: item.eventId == null
                ? null
                : () => AppScope.of(context).openEvent(item.eventId!),
          ),
      ],
    );
  }
}
