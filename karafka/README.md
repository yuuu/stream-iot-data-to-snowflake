# env-sensor dashboard consumer (Karafka)

`env-sensor-telemetry` トピックを **`dashboard-consumer-group`** で購読する Ruby 製コンシューマです。
MSK Connect + Snowflake Kafka Connector(グループ `connect-snowflake-env-sensor-sink`)とは
独立したコンシューマグループなので、同じトピックを**ファンアウト購読**します(オフセットは互いに独立)。

## 前提

- Ruby 4.x / Bundler
- MSK は VPC 内のため、ローカルからは踏み台 EC2 への **SSH ポートフォワード**経由で接続します。
  - `/etc/hosts` に各ブローカー FQDN → `127.0.0.2` / `127.0.0.3` / `127.0.0.4` を追記
  - `ssh -L 127.0.0.2:9096:b-1...:9096 -L 127.0.0.3:9096:b-2...:9096 -L 127.0.0.4:9096:b-3...:9096 ec2-user@<bastion>`
  - macOS では事前に `sudo ifconfig lo0 alias 127.0.0.2 up`(.3 / .4 も)が必要
- 認証は SASL_SSL / SCRAM-SHA-512。認証情報は `AmazonMSK_env-sensor_karafka` シークレット。

## セットアップ

```bash
cd karafka
bundle install

# .env を Secrets Manager から生成(.env は gitignore 対象)
AWS_PROFILE=fusic-sandbox bash bin/load-secret.sh
# もしくは env.sample をコピーして手で埋める

bundle exec karafka server
```

## ファイル

| ファイル | 役割 |
| --- | --- |
| `karafka.rb` | Karafka アプリ設定(bootstrap / SASL_SSL / SCRAM-SHA-512 / group_id / ルーティング) |
| `app/consumers/env_sensor_consumer.rb` | 受信 JSON をパースしてログ出力 + device_id 別の件数・最新値を集計 |
| `bin/load-secret.sh` | SCRAM 認証情報を Secrets Manager から取得して `.env` を生成 |
| `env.sample` | `.env` のテンプレート |
