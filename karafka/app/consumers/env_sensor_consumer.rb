# frozen_string_literal: true

# env-sensor-telemetry を購読し、受信 JSON をパースして
#   - 1 メッセージごとにログ出力(partition / offset / key / device_id / 値)
#   - device_id 別の受信件数と最新値をメモリ上に集計(簡易ダッシュボード相当)
# を行うコンシューマ。
class EnvSensorConsumer < Karafka::BaseConsumer
  # クラス変数で全パーティション横断の集計を保持(検証用途の簡易実装)
  @stats = Hash.new { |h, k| h[k] = { count: 0, last: nil, last_offset: nil } }

  class << self
    attr_reader :stats
  end

  def consume
    messages.each do |message|
      payload = parse(message.raw_payload)
      device_id = payload["device_id"] || message.key || "(unknown)"

      agg = self.class.stats[device_id]
      agg[:count] += 1
      agg[:last] = payload
      agg[:last_offset] = message.offset

      Karafka.logger.info(
        "[recv] p#{message.partition} o#{message.offset} key=#{message.key.inspect} " \
        "device_id=#{device_id} temp=#{payload['temperature']} hum=#{payload['humidity']} " \
        "pres=#{payload['pressure']} event_ts=#{payload['event_timestamp']}"
      )
    end

    log_summary
  end

  private

  def parse(raw)
    JSON.parse(raw)
  rescue JSON::ParserError => e
    Karafka.logger.warn("[recv] non-JSON payload (#{e.message}): #{raw.inspect}")
    {}
  end

  def log_summary
    lines = self.class.stats.sort.map do |device_id, agg|
      last = agg[:last] || {}
      format(
        "  %-16s count=%-4d last_offset=%-6s last_temp=%s",
        device_id, agg[:count], agg[:last_offset], last["temperature"]
      )
    end
    Karafka.logger.info("[dashboard] per-device summary (group=dashboard-consumer-group):\n#{lines.join("\n")}")
  end
end
