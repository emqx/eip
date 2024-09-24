# Improve Monitor Histogram

## Changelog

* 2024-09-24: @zmstone Initial draft

## Abstract

This EIP proposes to improve the monitor histogram implementation to make it more compact and efficient.

## Motivation

The current (as of 5.8) monitor histogram has below issues:

- It stores too much data but in the end only needed 1000 data points to return.
- The table is of type `set` making it impossible to perform in-place compaction.
- The data points are queried from clustered nodes using RPC calls, merged by the local node, sorted, then downsampled to 1000 records.
- The data points are formated as JSON array with repeated field names.

All these issues make the current implementation inefficient and slow and reflected as timeouts in the dashboard.

## Design

- Create a new `ordered_set` table, key being `{Timestamp, node()}` and value being the counters and gauges in a map.
- Do not use `local_content` for the table, so there is no need to RPC when querying the data.
- For counters, store absolute values instead of calculating deltas. This makes compaction easier: simply downsample the data points.
- Each node downsample its own data points to less than 1000 points in the table. See downsampling algorithm below.
- Return more compact data format in the API response. See API response format below.
- Store the aggregated data points in a ets table for each node locally to speed up the query.

### Downsampling Algorithm

The downsampling algorithm is as follows:

- For `0-1h`, keep 1 data point per `10s`, (60 * 6 = 360) data points in total.
- For `1h-24h`, keep 1 data point per `5m`,  (23 * 12 = 276) data points in total.
- For `24h-7d`, keep 1 data point per `30m`, (6 * 24 * 2 = 288) data points in total.

The total number of downsampling data points should not exceed `924`.

When downsampling, the data point which is earlier but closest to a wall clock aligned interval should be kept.

For example:

- Delete records in range `(12:35:00, 12:35:10)`, but retain the last recrod using key `12:35:10` when interval is `10s`.
- Delete records in range `(12:35:00, 12:40:00)`, but retain the last record using key `12:40:00` when interval is `5m`.
- Delete records in range `(12:30:00, 12:59:50)`, but retain the last record using key `13:00:00` when interval is `30m`.

### API Response Format

Return header + two-dimensional array of data points.

For example:

```json
{
    "header": ["time", "received", "sent", "dropped"],
    "data": [
        [1727206017, 100, 99, 1],
        [1727206027, 200, 199, 1]
    ]
}
```

## Configuration Changes

There is no configuration changes.

## Backwards Compatibility

In order to be backwards compatible with older version of EMQX, the new monitor histogram will have to facilitate the old data format.
A new query parameter `?v=2` can be added to the `/monitor` API endpoint to request the new format.

## Document Changes

If there is any document change, give a brief description of it here.

## Testing Suggestions

The final implementation must include unit test or common test code. If some
more tests such as integration test or benchmarking test that need to be done
manually, list them here.

## Declined Alternatives

