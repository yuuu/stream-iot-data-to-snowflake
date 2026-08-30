# frozen_string_literal: true

# ダッシュボード側の Kafka コンシューマ(Karafka)。
#
# MSK Connect + Snowflake Kafka Connector(コンシューマグループ connect-snowflake-env-sensor-sink)
# とは独立したコンシューマグループ dashboard-consumer-group で、同じトピック
# env-sensor-telemetry をファンアウト購読する。
#
# 認証は SASL_SSL / SCRAM-SHA-512。認証情報(AmazonMSK_env-sensor_karafka)は
# .env(gitignore)経由で渡す。bin/load-secret.sh で Secrets Manager から取得できる。
# MSK は VPC 内なので、ローカルからは踏み台 EC2 への SSH ポートフォワード経由で接続する
# (/etc/hosts で b-1..b-3 を 127.0.0.2..4 に解決 → ssh -L で各 9096 を転送)。

require "dotenv/load"
require "karafka"
require "json"

# ログをパイプ/ファイルへリダイレクトしたときも即時フラッシュする(検証で追いやすくするため)
$stdout.sync = true
$stderr.sync = true

require_relative "app/consumers/env_sensor_consumer"

class KarafkaApp < Karafka::App
  setup do |config|
    brokers = ENV.fetch(
      "KAFKA_BOOTSTRAP",
      "b-1.envsensorkafka.2ci9mq.c4.kafka.ap-northeast-1.amazonaws.com:9096," \
      "b-2.envsensorkafka.2ci9mq.c4.kafka.ap-northeast-1.amazonaws.com:9096," \
      "b-3.envsensorkafka.2ci9mq.c4.kafka.ap-northeast-1.amazonaws.com:9096"
    )

    config.kafka = {
      "bootstrap.servers": brokers,
      "security.protocol": "sasl_ssl",
      "sasl.mechanisms": "SCRAM-SHA-512",
      "sasl.username": ENV.fetch("KAFKA_SASL_USERNAME"),
      "sasl.password": ENV.fetch("KAFKA_SASL_PASSWORD"),
      "ssl.ca.location": ENV.fetch("KAFKA_SSL_CA_LOCATION", "/etc/ssl/cert.pem"),
      # 初回は先頭から読む(検証で過去メッセージも見たいため)
      "auto.offset.reset": "earliest"
    }

    config.client_id = "env-sensor-dashboard"
    # MSK Connect の connect-* グループとは別のグループ ID(ファンアウトの肝)
    config.group_id = "dashboard-consumer-group"
    config.max_wait_time = 1_000
  end

  routes.draw do
    topic "env-sensor-telemetry" do
      consumer EnvSensorConsumer
    end
  end
end
