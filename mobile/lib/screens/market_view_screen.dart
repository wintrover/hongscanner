import 'package:flutter/material.dart';

import '../api/api_models.dart';
import '../state/app_store.dart';
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
              loaded: (context, marketView) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _refreshFailureCard(store),
                  _Top10sBody(
                    marketView: marketView,
                    refreshing: store.isRefreshing,
                  ),
                ],
              ),
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
              loaded: (context, marketView) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _refreshFailureCard(store),
                  _HistoryBody(marketView: marketView),
                ],
              ),
              onRetry: store.resync,
            ),
          ],
        ),
      ),
    );
  }
}

/// A refresh failure shown beside retained content: the same offline/error
/// card the initial-load failure uses, with the last-projection note in
/// its message. Returns nothing while the last refresh succeeded.
Widget _refreshFailureCard(AppStore store) {
  final message = store.refreshErrorMessage;
  if (message == null) return const SizedBox.shrink();
  return SectionErrorCard(
    message: '마지막 데이터를 표시 중 · $message',
    offline: store.refreshOffline,
    onRetry: store.resync,
  );
}

/// `HH:MM:SS` from a full, parseable ISO 8601 payload timestamp; '—' when
/// the timestamp is missing or unparseable. Never a substring guess.
String _clockLabel(String? isoTimestamp) {
  if (isoTimestamp == null || isoTimestamp.length < 19) return '—';
  if (DateTime.tryParse(isoTimestamp) == null) return '—';
  return isoTimestamp.substring(11, 19);
}

/// `data_as_of` banner clock: `HH:MM:SS`, prefixed with `MM-DD ` when the
/// payload's data timestamp falls on a different date than its decision
/// timestamp (a stale previous-session projection must not read as today's
/// data). Only the two payload timestamps are compared — never the device
/// clock. A missing or unparseable timestamp yields '—' / no date prefix
/// rather than a guess.
String _dataClockLabel(String? modeAsOf, String? dataAsOf) {
  final clock = _clockLabel(dataAsOf);
  if (clock == '—') return '—';
  final dataDate = _isoDate(dataAsOf);
  final modeDate = _isoDate(modeAsOf);
  if (dataDate == null || modeDate == null || dataDate == modeDate) {
    return clock;
  }
  return '${dataDate.substring(5)} $clock';
}

/// The `YYYY-MM-DD` text of a parseable full ISO 8601 payload timestamp.
/// Kept as text so the recorded calendar date is compared without
/// converting through the device timezone.
String? _isoDate(String? timestamp) {
  if (timestamp == null || timestamp.length < 19) return null;
  if (DateTime.tryParse(timestamp) == null) return null;
  return timestamp.substring(0, 10);
}

/// Lateness suffix from the payload's own two timestamps: ` · N분 지연`
/// when the data timestamp trails the decision timestamp by 60s or more
/// (truncating toward whole minutes — `1038s` reads `17분`). The instants
/// are parsed with their recorded UTC offsets, so the comparison is
/// offset-independent. Anything missing or unparseable yields '' — no
/// guess.
String _delaySuffix(String? modeAsOf, String? dataAsOf) {
  if (modeAsOf == null || modeAsOf.length < 19 ||
      dataAsOf == null || dataAsOf.length < 19) {
    return '';
  }
  final modeAt = DateTime.tryParse(modeAsOf);
  final dataAt = DateTime.tryParse(dataAsOf);
  if (modeAt == null || dataAt == null) return '';
  final lag = modeAt.difference(dataAt);
  if (lag.inSeconds < 60) return '';
  return ' · ${lag.inMinutes}분 지연';
}

class _Top10sBody extends StatelessWidget {
  const _Top10sBody({
    required this.marketView,
    required this.refreshing,
  });

  final MarketViewResponse marketView;

  /// True while a poll is refreshing this already-visible projection.
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    // opening_ma20 mode redefines both lists: the rows rank the price
    // against the 20-day moving average over the opening 30 minutes,
    // not the day's change rate, so only that mode gets the
    // disambiguating headers. core mode keeps the pre-mode headerless
    // cards verbatim — mode switches labels, never the row order or
    // the classification. The banner above both cards names the mode
    // the server decided and its mode_as_of clock.
    final ma20Mode = marketView.mode == 'opening_ma20';
    final coverage = marketView.coverage;
    // The mode banner names what the server projected and when it decided
    // it (mode_as_of) — and, separately, the last recorded observation
    // the rows were built from (data_as_of). The delay/date annotation is
    // derived only from those two payload timestamps (never the device
    // clock); a missing or unparseable timestamp shows '—' or nothing,
    // never a fabricated one.
    final modeAsOf = marketView.modeAsOf;
    final modeClock = _clockLabel(modeAsOf);
    final dataAsOf = marketView.dataAsOf;
    final dataClock = _dataClockLabel(modeAsOf, dataAsOf);
    final delaySuffix = _delaySuffix(modeAsOf, dataAsOf);
    final refreshSuffix = refreshing ? ' · 갱신 중' : '';
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
                Text(
                  ma20Mode ? '개장 MA20 순위' : '일반 TOP10',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '판정 $modeClock · 데이터 $dataClock$delaySuffix$refreshSuffix',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        if (ma20Mode && coverage != null) ...[
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '수집 상태: ${coverage.status ?? '?'} · MA20 계산 가능 '
                '${coverage.computableCount ?? '?'}/관측 대상 '
                '${coverage.candidateCount ?? '?'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        ],
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ma20Mode) ...[
                  Text(
                    '상승 TOP 10 (MA20 위)'
                        '${coverage?.risingComplete == false ? ' · PARTIAL ${coverage?.risingCount ?? '?'}종' : ''}',
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
                  Text(
                    '하락 TOP 10 (MA20 아래)'
                        '${coverage?.fallingComplete == false ? ' · PARTIAL ${coverage?.fallingCount ?? '?'}종' : ''}',
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
            // The vendor's full-market rank, not the row's position in
            // this MA20 projection — the label says so.
            title: Text('${_itemTitle(item)} (전체 ${item.rank ?? '—'}위)'),
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
