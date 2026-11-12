/// Typed projections of the VS-3 read-only API responses.
///
/// Contract: tools/api/README.md. Every model mirrors exactly what the
/// contract serves — recorded facts plus the cheap rederivations the
/// contract names. `null` is never coerced: the contract defines null as
/// "no record" (absence), which is different from 0 or false, and the
/// models keep that distinction so the UI can stay honest about it.
library;

String? _asString(Object? v) => v is String ? v : null;

int? _asInt(Object? v) => v is int ? v : null;

bool _asBoolOr(Object? v, bool fallback) => v is bool ? v : fallback;

Map<String, Object?> _asMap(Object? v) =>
    v is Map<String, Object?> ? v : const <String, Object?>{};

List<Map<String, Object?>> _asMapList(Object? v) => v is List
    ? v.whereType<Map<String, Object?>>().toList()
    : const <Map<String, Object?>>[];

Map<String, int>? _asIntMap(Object? v) => v is Map<String, Object?>
    ? v.map((k, value) => MapEntry(k, _asInt(value) ?? 0))
    : null;

/// One immutable event fact (contracts/events/event.schema.json,
/// "hong-scanner-event-fact/1"). [raw] keeps the fact bytes' fields so the
/// UI can show the recorded fact verbatim without merging anything into it.
class ApiEvent {
  const ApiEvent(this.raw);

  factory ApiEvent.fromMap(Map<String, Object?> raw) => ApiEvent(raw);

  final Map<String, Object?> raw;

  String? get eventId => _asString(raw['event_id']);
  String? get eventType => _asString(raw['event_type']);
  String? get observedAt => _asString(raw['observed_at']);
  String? get sessionId => _asString(raw['session_id']);
  String? get severity => _asString(raw['severity']);
  String? get dataQuality => _asString(raw['data_quality']);
  String? get ruleId => _asString(raw['rule_id']);
  int? get ruleVersion => _asInt(raw['rule_version']);
  String? get evidenceRef => _asString(raw['evidence_ref']);

  /// Judged direction; absent when the fact judged no direction.
  String? get direction => _asString(raw['direction']);

  /// The vendor row's stock name preserved by the input normalization
  /// boundary; absent when the row carried none — the symbol is the
  /// display fallback, never a re-parse of a raw response.
  String? get name => _asString(raw['name']);

  /// Rank in the same direction at the end of the previous confirmed
  /// observation group; present only on top10-transition facts (the
  /// "from" rank of a rank change or TOP10 in/out transition).
  int? get previousRank => _asInt(raw['previous_rank']);

  /// Candidate rank; absent for rank-free facts.
  int? get rank => _asInt(raw['rank']);

  /// 6-digit KRX code; absent for non-symbol-scoped facts.
  String? get symbol => _asString(raw['symbol']);

  /// Recorded fact keys in codepoint-ascending order (the API serves
  /// canonical JSON, so this is already the wire order; sorting is a
  /// display-stability guarantee, not a re-derivation).
  List<MapEntry<String, Object?>> get sortedFields {
    final entries = raw.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries;
  }
}

/// One delivery-ledger record (contracts/events/delivery.schema.json).
/// Delivery state is operational state — it never lives inside a fact.
class DeliveryRecord {
  const DeliveryRecord(this.raw);

  factory DeliveryRecord.fromMap(Map<String, Object?> raw) =>
      DeliveryRecord(raw);

  final Map<String, Object?> raw;

  String? get eventId => _asString(raw['event_id']);
  String? get deviceId => _asString(raw['device_id']);
  String? get state => _asString(raw['state']);
  int? get attempts => _asInt(raw['attempts']);
  String? get providerMessageId => _asString(raw['provider_message_id']);
  String? get updatedAt => _asString(raw['updated_at']);
}

/// `GET /events/{event_id}` response.
class EventDetailResponse {
  const EventDetailResponse({required this.event, required this.delivery});

  factory EventDetailResponse.fromMap(Map<String, Object?> raw) =>
      EventDetailResponse(
        event: ApiEvent.fromMap(_asMap(raw['event'])),
        delivery: _asMapList(raw['delivery']).map(DeliveryRecord.fromMap).toList(),
      );

  final ApiEvent event;

  /// Empty list when no delivery has been recorded — the honest absence
  /// the contract documents.
  final List<DeliveryRecord> delivery;
}

/// One `/mobile/market-view` projection item: a server-ranked row of the
/// rising/falling top 10 or a TOP10 state-change record of the retained
/// history. The server projection is authoritative — the app never
/// recomputes ranks or derives changes, so this model is a read-only
/// display projection, not a re-derivation.
class MarketViewItem {
  const MarketViewItem({
    this.changeType,
    this.dataQuality,
    this.direction,
    this.eventId,
    this.eventType,
    this.ma20Tag,
    this.name,
    this.observedAt,
    this.prevRank,
    this.rank,
    this.symbol,
  });

  factory MarketViewItem.fromMap(Map<String, Object?> raw) => MarketViewItem(
        changeType: _asString(raw['change_type']),
        dataQuality: _asString(raw['data_quality']),
        direction: _asString(raw['direction']),
        eventId: _asString(raw['event_id']),
        eventType: _asString(raw['event_type']),
        ma20Tag: _asString(raw['ma20_tag']),
        name: _asString(raw['name']),
        observedAt: _asString(raw['observed_at']),
        prevRank: _asInt(raw['prev_rank']),
        rank: _asInt(raw['rank']),
        symbol: _asString(raw['symbol']),
      );

  /// TOP10 state-change kind: TOP10_ENTERED / TOP10_EXITED /
  /// CANDIDATE_EXITED / RANK_CHANGED. History items only — top-10 rows
  /// carry the ledger event_type instead.
  final String? changeType;

  final String? dataQuality;
  final String? direction;
  final String? eventId;
  final String? eventType;

  /// Opening-window MA20 position: ABOVE = price above the 20-day moving
  /// average, BELOW = below it; null = no tag (out-of-window rows and
  /// core-mode rows carry none). Verbatim from the projection — the app
  /// never derives or corrects it.
  final String? ma20Tag;

  /// Recorded stock name; null when the ledger has no name record —
  /// honest absence, displayed as the symbol fallback.
  final String? name;

  final String? observedAt;

  /// Rank recorded in the previous observation group; null = no prior
  /// state (a new candidate). History items only.
  final int? prevRank;

  /// Rank: the row's rank on top-10 items, the new rank after the change
  /// on history items. null on CANDIDATE_EXITED history items — honest
  /// absence, never rendered as 0.
  final int? rank;

  /// 6-digit KRX code.
  final String? symbol;
}

/// `latest` block of the market view: the newest retained candidate
/// event's identifying fields. The projection does not rank it, so it
/// carries no direction/rank/symbol.
class MarketViewLatest {
  const MarketViewLatest({
    this.dataQuality,
    this.eventId,
    this.eventType,
    this.observedAt,
  });

  factory MarketViewLatest.fromMap(Map<String, Object?> raw) =>
      MarketViewLatest(
        dataQuality: _asString(raw['data_quality']),
        eventId: _asString(raw['event_id']),
        eventType: _asString(raw['event_type']),
        observedAt: _asString(raw['observed_at']),
      );

  final String? dataQuality;
  final String? eventId;
  final String? eventType;
  final String? observedAt;
}

/// `run` block of the market view: the eligible run the projection was
/// computed from. null (or `runs_present == false`) means no eligible run
/// was recorded — "기록 없음", never a zero-filled run.
class MarketViewRun {
  const MarketViewRun({
    this.session,
    this.sessionDate,
    this.runId,
    this.startedAt,
  });

  factory MarketViewRun.fromMap(Map<String, Object?> raw) => MarketViewRun(
        session: _asString(raw['session']),
        sessionDate: _asString(raw['session_date']),
        runId: _asString(raw['run_id']),
        startedAt: _asString(raw['started_at']),
      );

  final String? session;
  final String? sessionDate;
  final String? runId;
  final String? startedAt;
}

/// `status` block of the market view: candidate counts by data_quality.
/// Rendered verbatim — INCOMPLETE/UNKNOWN stay visible, never flattened
/// to normal.
class MarketViewStatus {
  const MarketViewStatus({this.byDataQuality});

  factory MarketViewStatus.fromMap(Map<String, Object?> raw) =>
      MarketViewStatus(byDataQuality: _asIntMap(raw['by_data_quality']));

  final Map<String, int>? byDataQuality;
}

/// `GET /mobile/market-view` response: the single bounded projection the
/// phone renders — the rising/falling top 10 (server-ranked, ascending
/// rank) and the retained TOP10 state-change records (≤100, server
/// order: oldest→newest; TOP10_ENTERED / TOP10_EXITED / CANDIDATE_EXITED
/// / RANK_CHANGED), plus the run/as_of context. The client never
/// reorders or refilters anything here: the server order is the display
/// order.
class MarketViewResponse {
  const MarketViewResponse({
    required this.asOf,
    required this.history,
    required this.latest,
    required this.mode,
    required this.run,
    required this.risingTop10,
    required this.fallingTop10,
    required this.runsPresent,
    required this.status,
  });

  factory MarketViewResponse.fromMap(Map<String, Object?> raw) {
    final latest = raw['latest'];
    final run = raw['run'];
    final status = raw['status'];
    return MarketViewResponse(
      asOf: _asString(raw['as_of']),
      history:
          _asMapList(raw['history']).map(MarketViewItem.fromMap).toList(),
      latest: latest is Map<String, Object?>
          ? MarketViewLatest.fromMap(latest)
          : null,
      mode: _asString(raw['mode']) ?? 'core',
      run: run is Map<String, Object?> ? MarketViewRun.fromMap(run) : null,
      risingTop10:
          _asMapList(raw['rising_top10']).map(MarketViewItem.fromMap).toList(),
      fallingTop10:
          _asMapList(raw['falling_top10']).map(MarketViewItem.fromMap).toList(),
      runsPresent: _asBoolOr(raw['runs_present'], false),
      status:
          status is Map<String, Object?> ? MarketViewStatus.fromMap(status) : null,
    );
  }

  /// Projection timestamp; null when the server recorded none.
  final String? asOf;

  /// Retained TOP10 state-change records in server order
  /// (oldest→newest), ≤100.
  final List<MarketViewItem> history;

  final MarketViewLatest? latest;

  /// Projection mode: 'core' = the day's change-rate classification,
  /// 'opening_ma20' = the opening 30 minutes (09:00–09:30) classified
  /// against the 20-day moving average. The contract has the server
  /// always send it; a missing or unrecognized value keeps 'core' — the
  /// pre-mode display — never a fabricated opening_ma20 reading. Display
  /// only: the app switches its labels on it, never the row order or
  /// the classification.
  final String mode;

  /// Eligible run context; null = no eligible run recorded.
  final MarketViewRun? run;

  final List<MarketViewItem> risingTop10;
  final List<MarketViewItem> fallingTop10;

  /// False (or [run] null) means no eligible run was recorded — displayed
  /// as "기록 없음", never as fake zeros.
  final bool runsPresent;

  final MarketViewStatus? status;
}
