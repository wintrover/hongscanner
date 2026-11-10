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

/// 히스토리 tab: the retained TOP10 state-change records (≤100, server
/// order: oldest→newest). Same single projection as the 후보 tab — a tab
/// switch reads the store, it never refetches.
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
    // opening_ma20 mode redefines both lists: the rows rank the price
    // against the 20-day moving average over the opening 30 minutes,
    // not the day's change rate, so only that mode gets the
    // disambiguating headers. core mode keeps the pre-mode headerless
    // cards verbatim — mode switches labels, never the row order or
    // the classification.
    final ma20Mode = marketView.mode == 'opening_ma20';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ma20Mode) ...[
                  Text('상승 TOP 10 (MA20 위)',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                ],
                _Top10List(
                  items: marketView.risingTop10,
                  direction: 'UP',
                  emptyMessage: '상승 TOP 10 기록 없음',
                ),
              ],
            ),
          ),
        ),
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ma20Mode) ...[
                  Text('하락 TOP 10 (MA20 아래)',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                ],
                _Top10List(
                  items: marketView.fallingTop10,
                  direction: 'DOWN',
                  emptyMessage: '하락 TOP 10 기록 없음',
                ),
              ],
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
          emptyMessage: '변화 기록 없음',
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

/// MA20 tag label: ABOVE = 'MA20 위', BELOW = 'MA20 아래'. Any other
/// value (null included — out-of-window rows, core-mode rows) has no
/// label: an unrecognized tag is never guessed into one of the two
/// positions.
String? _ma20TagLabel(String? tag) => switch (tag) {
      'ABOVE' => 'MA20 위',
      'BELOW' => 'MA20 아래',
      _ => null,
    };

/// Top-10 row trailing: the chevron, preceded by the projection's MA20
/// tag badge when the row carries a recognizable one (opening_ma20
/// mode). The badge shows the server's tag verbatim — it is never
/// derived from price data in the app.
Widget _top10Trailing(BuildContext context, MarketViewItem item) {
  final label = _ma20TagLabel(item.ma20Tag);
  if (label == null) return const Icon(Icons.chevron_right);
  final scheme = Theme.of(context).colorScheme;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Badge(
        backgroundColor: scheme.secondaryContainer,
        textColor: scheme.onSecondaryContainer,
        label: Text(label),
      ),
      const SizedBox(width: 8),
      const Icon(Icons.chevron_right),
    ],
  );
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
            trailing: _top10Trailing(context, item),
            onTap: item.eventId == null
                ? null
                : () => AppScope.of(context).openEvent(item.eventId!),
          ),
      ],
    );
  }
}

/// History rank suffix: ` #prev→rank` when the previous observation
/// group recorded a rank, ` #rank` alone when there was no prior state
/// (prevRank null — a new candidate), and '' when rank is null
/// (CANDIDATE_EXITED) — honest absence, never a fake 0.
String _historyRankSuffix(MarketViewItem item) {
  final rank = item.rank;
  if (rank == null) return '';
  final prevRank = item.prevRank;
  return prevRank == null ? ' #$rank' : ' #$prevRank→$rank';
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
              '${item.changeType ?? '?'} · ${_itemTitle(item)}'
              '${item.direction == null ? '' : ' · ${item.direction}'}'
              '${_historyRankSuffix(item)}',
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
