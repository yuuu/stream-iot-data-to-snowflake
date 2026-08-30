# stream-iot-data-to-snowflake

M5Stack(ENV3ユニット)で計測した温度・湿度・気圧データを、AWS IoT Core → Kinesis Data Firehose → Snowpipe Streaming 経由でSnowflakeへストリーミング・蓄積するためのTerraform構成です。
蓄積したデータはDynamic Tableでdevice_id・1時間単位に集計し、1時間毎の平均値を保持します。

構築の過程は以下の記事にまとめています。

- (執筆中)IoTデバイスで収集したデータをAWS経由でSnowflakeへ配信・蓄積する方法
- (執筆中)Snowflake Dynamic tablesを使ってIoTデバイスから収集したデータをELTする
- (執筆中)IoT Core → Apache Kafka(Amazon MSK) → Snowflake：Kafkaを挟んでファンアウト購読する(`terraform/kafka/` ・ `karafka/`)

## 構成

**Firehose 版**（`terraform/`）:

```
M5Stack(ENV3) --MQTT/TLS--> AWS IoT Core --IoT Rule--> Kinesis Data Firehose --Snowpipe Streaming--> Snowflake(ENV_SENSOR_RAW) --Dynamic Table--> ENV_SENSOR_HOURLY_AVG
```

**Kafka(MSK) 版**（`terraform/kafka/` ・ `karafka/`。Firehose 版とは独立して構築・破棄できる別モジュール）:

```
aws iot-data publish / M5Stack --MQTT/TLS--> AWS IoT Core
  --IoT Rule(Kafka Action, VPC destination)--> Amazon MSK (env-sensor-telemetry / SASL/SCRAM + IAM)
      ├─ MSK Connect + Snowflake Kafka Connector (IAM認証 / Snowpipe Streaming) --> Snowflake(ENV_SENSOR_RAW)
      └─ Karafka (dashboard-consumer-group / SASL/SCRAM / ローカル実行 + 踏み台への SSH ポートフォワード)
```

同じトピックを 2 つのコンシューマグループ（MSK Connect と Karafka）が独立して購読するファンアウト構成です。

デバイス側のソースコードは https://github.com/yuuu/aws-m5stack-iot-handson-book-site/tree/main/device を利用しています。

## ディレクトリ構成

```
terraform/                # Firehose 版(1〜2本目の記事)
├── versions.tf           # Terraform / provider バージョン制約
├── providers.tf          # aws / snowflake provider設定
├── variables.tf
├── iot.tf                # AWS IoT Core(Thing, Policy, Topic Rule) ※証明書自体はTerraform管理外
├── firehose.tf           # Kinesis Data Firehose(Snowflake destination), S3, IAM
├── snowflake.tf          # Snowflake側のDatabase/Schema/Table/Role/Service User
├── dynamic_table.tf      # 1時間毎の集計用Warehouse・Dynamic Table
└── outputs.tf

terraform/kafka/          # Kafka(MSK) 版(Kafkaを挟む構成の記事)。親と state 別の独立ルートモジュール
├── versions.tf / providers.tf / variables.tf / outputs.tf
├── vpc.tf                # 専用VPC(private×3 / public×1)+ IGW + ルートテーブル
├── msk.tf                # MSK Provisioned(SASL/SCRAM + IAM)+ KMS + Secrets Manager
├── bastion.tf            # 踏み台EC2(SSHジャンプホスト)。鍵はTerraform生成
├── iot_kafka.tf          # IoT Rule の Kafka Action + VPC destination + IAMロール
├── nat.tf                # NAT Gateway(MSK ConnectのSnowflake向け通信)+ S3ゲートウェイエンドポイント
├── msk_connect.tf        # MSK Connect カスタムプラグイン + Snowflake Kafka Connector
├── snowflake_kafka.tf    # 専用のDatabase/Schema/Table/Role/Service User(親モジュールと非共有)
└── scripts/
    ├── lo-setup.sh       # (macOS) ローカルからのSSHポートフォワード用の下準備(loopbackエイリアス + /etc/hosts)
    └── lo-teardown.sh    # 上記の後始末

karafka/                  # ダッシュボード側コンシューマ(Ruby / Karafka)
├── karafka.rb / app/consumers/env_sensor_consumer.rb
├── bin/load-secret.sh    # SASL/SCRAM認証情報をSecrets Managerから取得して .env を生成
├── env.sample / Gemfile / README.md
```

## 事前準備

1. AWS CLIプロファイル(`terraform.tfvars` の `aws_profile` で指定)で認証できること
2. Snowflakeに管理用ロール・サービスユーザー(キーペア認証)を用意すること
3. AWS IoT証明書を用意し、そのARNを控えておくこと

### Snowflake管理用ユーザーの準備

Terraformが database / schema / role / user を作成できるよう、ACCOUNTADMINロールで一度だけ以下を実行します。

```bash
# 1. キーペアを生成
mkdir -p ~/.secrets/snowflake
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out ~/.secrets/snowflake/tf_admin_key.p8 -nocrypt
openssl rsa -in ~/.secrets/snowflake/tf_admin_key.p8 -pubout -out ~/.secrets/snowflake/tf_admin_key.pub

# 2. 公開鍵をSQLに貼り付けられる1行文字列に変換
grep -v -- '-----' ~/.secrets/snowflake/tf_admin_key.pub | tr -d '\n'
```

Snowsight(ACCOUNTADMINロール)で以下のSQLを実行します(`<...>`は上記で得た公開鍵の1行文字列に置き換え)。

```sql
CREATE ROLE IF NOT EXISTS IOT_STREAM_TF_ADMIN_ROLE;
GRANT ROLE IOT_STREAM_TF_ADMIN_ROLE TO ROLE SYSADMIN;

CREATE USER IF NOT EXISTS IOT_STREAM_TF_ADMIN_USER
  TYPE = SERVICE
  DEFAULT_ROLE = IOT_STREAM_TF_ADMIN_ROLE
  RSA_PUBLIC_KEY = '<公開鍵の1行文字列>';

GRANT ROLE IOT_STREAM_TF_ADMIN_ROLE TO USER IOT_STREAM_TF_ADMIN_USER;

GRANT CREATE DATABASE ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
GRANT CREATE ROLE ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
GRANT CREATE USER ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
GRANT MANAGE GRANTS ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
```

アカウント識別子は以下で確認できます。

```sql
SELECT CURRENT_ORGANIZATION_NAME() AS org_name, CURRENT_ACCOUNT_NAME() AS account_name;
```

### AWS IoT証明書の準備

`aws_iot_certificate` はTerraformのimportに対応しておらず、秘密鍵も作成時にしか取得できないため、証明書はTerraform管理外とし、事前にAWS CLIで作成します。

```bash
aws iot create-keys-and-certificate --set-as-active \
  --certificate-pem-outfile certs/device-certificate.pem.crt \
  --public-key-outfile certs/device-public.pem.key \
  --private-key-outfile certs/device-private.pem.key
```

出力される `certificateArn` を、後述の `terraform.tfvars` の `device_certificate_arn` に設定してください。

`terraform/terraform.tfvars.example` を `terraform.tfvars` としてコピーし、上記で得た値を設定してください(`terraform.tfvars` はgitignore対象です)。

## 実行(Firehose 版)

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## Kafka(MSK)構成を試す(`terraform/kafka/`)

Firehose 版とは独立した別ルートモジュールです（state も `terraform.tfvars` も別）。
前提は Firehose 版と同じ（AWS CLI プロファイル / キーペア認証の Snowflake 管理ユーザー）で、
`terraform/kafka/terraform.tfvars.example` を `terraform.tfvars` にコピーして値を設定します
（AWS プロファイル・リージョン・SSH 許可元 CIDR・Snowflake の org/account/管理ユーザー/秘密鍵パス）。

> **コスト注意**: MSK Provisioned（`kafka.t3.small` ×3）+ NAT Gateway + MSK Connect（1 MCU）+ 踏み台 EC2 で
> 概算 **~$5/日** かかります。検証が終わったら必ず `terraform destroy` してください。

```bash
cd terraform/kafka
terraform init
terraform plan
terraform apply
```

- 初回 `apply` 時、Snowflake Kafka Connector の JAR（約 185MB）を Maven Central から
  `terraform/kafka/build/` に取得します（`terraform_data` + `curl`。ネットワーク必須。`build/` は gitignore 対象）。
- MSK クラスタの作成に 20〜40 分、MSK Connect コネクタの作成に 5〜15 分かかります。
- テーブル `IOT_STREAM_KAFKA_DB.ENV_SENSOR_KAFKA.ENV_SENSOR_RAW` は Terraform で作成し、
  Snowflake Kafka Connector が `schematization=true` で型付きカラム（`TEMPERATURE` 等）へ書き込みます。

### 認証方式

MSK は SASL/SCRAM と IAM の両方を有効化しています。コンポーネントごとに使い分けます。

| コンポーネント | MSK への接続 |
| --- | --- |
| IoT Rule の Kafka Action | SASL/SCRAM（Kafka Action は IAM 非対応） |
| MSK Connect（Snowflake Kafka Connector） | IAM（MSK Connect は SASL/SCRAM が実質不可） |
| Karafka | SASL/SCRAM |

### Karafka コンシューマをローカルで動かす

MSK は VPC 内にあるため、ローカルからは**踏み台 EC2 への SSH ポートフォワード**で接続します。
macOS ではブローカー数ぶんのループバックエイリアスと `/etc/hosts` 追記が必要です（`sudo` が必要）。

```bash
# 1) loopback エイリアス(127.0.0.2..) と /etc/hosts を用意(要 sudo。後始末は lo-teardown.sh)
sudo bash terraform/kafka/scripts/lo-setup.sh

# 2) 踏み台経由でブローカー分のポートフォワードを張る(FQDN は terraform output を参照)
#    例:
ssh -i terraform/kafka/certs/bastion_ed25519.pem -N \
  -L 127.0.0.2:9096:b-1.xxx.kafka.ap-northeast-1.amazonaws.com:9096 \
  -L 127.0.0.3:9096:b-2.xxx.kafka.ap-northeast-1.amazonaws.com:9096 \
  -L 127.0.0.4:9096:b-3.xxx.kafka.ap-northeast-1.amazonaws.com:9096 \
  ec2-user@$(terraform -chdir=terraform/kafka output -raw bastion_public_ip)

# 3) 認証情報(.env)を Secrets Manager から生成して Karafka を起動
cd karafka
bundle install
AWS_PROFILE=<your-profile> bash bin/load-secret.sh   # karafka/.env を生成(gitignore 対象)
bundle exec karafka server
```

`aws iot-data publish` でテストメッセージを送ると、Karafka のログ（`[recv] ...`）と
Snowflake の `ENV_SENSOR_RAW` の両方に同じレコードが現れます。

> **JDK の注意**: JDK 24 以降では Kafka 同梱の JVM 製 CLI（`kafka-console-consumer.sh` など）の
> SASL 認証が動きません。ローカルでの疎通確認は Karafka（librdkafka ベース）か、
> 踏み台 EC2 上の JDK 17 で行ってください。

### 破棄

```bash
cd terraform/kafka
terraform destroy

# ローカル側の後始末(macOS)
sudo bash scripts/lo-teardown.sh
# 起動したままの SSH トンネル / Karafka プロセスも停止する
```

## 注意事項

- 本リポジトリはpublicです。証明書・秘密鍵・`*.tfvars`・`*.tfstate`・`karafka/.env`・`terraform/kafka/build/` は `.gitignore` で除外していますが、コミット前に必ず `git status` / `git diff --cached` で機密情報が含まれていないか確認してください。
- `terraform apply` はAWS・Snowflake双方で実際にリソースを作成し、課金が発生します。不要になったら `terraform destroy` してください（Kafka 版は特に MSK/NAT/MSK Connect の課金が大きいので忘れずに）。
