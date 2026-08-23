# stream-iot-data-to-snowflake

M5Stack(ENV3ユニット)で計測した温度・湿度・気圧データを、AWS IoT Core → Kinesis Data Firehose → Snowpipe Streaming 経由でSnowflakeへストリーミング・蓄積するためのTerraform構成です。
蓄積したデータはDynamic Tableでdevice_id・1時間単位に集計し、1時間毎の平均値を保持します。
また、ENV_SENSOR_RAWのTEMPERATUREが30度を超えた行をSnowflake Alertで検知し、ログテーブルへの記録とメール通知を行います。

構築の過程は以下の記事にまとめています。

- (執筆中)IoTデバイスで収集したデータをAWS経由でSnowflakeへ配信・蓄積する方法
- (執筆中)Snowflake Dynamic tablesを使ってIoTデバイスから収集したデータをELTする
- (執筆中)Snowflake Alertを使ってIoTデバイスから収集したデータのしきい値超過を検知する

## 構成

```
M5Stack(ENV3) --MQTT/TLS--> AWS IoT Core --IoT Rule--> Kinesis Data Firehose --Snowpipe Streaming--> Snowflake(ENV_SENSOR_RAW) --Dynamic Table--> ENV_SENSOR_HOURLY_AVG
                                                                                       └--Alert(TEMPERATURE > 30)--> ENV_SENSOR_TEMPERATURE_ALERT_LOG / メール通知
```

デバイス側のソースコードは https://github.com/yuuu/aws-m5stack-iot-handson-book-site/tree/main/device を利用しています。

## ディレクトリ構成

```
terraform/
├── versions.tf       # Terraform / provider バージョン制約
├── providers.tf      # aws / snowflake provider設定
├── variables.tf
├── iot.tf            # AWS IoT Core(Thing, Policy, Topic Rule) ※証明書自体はTerraform管理外
├── firehose.tf       # Kinesis Data Firehose(Snowflake destination), S3, IAM
├── snowflake.tf      # Snowflake側のDatabase/Schema/Table/Role/Service User
├── dynamic_table.tf  # 1時間毎の集計用Warehouse・Dynamic Table
├── alert.tf          # TEMPERATURE超過検知用Warehouse・Alert・ログテーブル・Notification Integration
└── outputs.tf
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

-- Alert(alert.tf)用。EXECUTE ALERT / CREATE INTEGRATION はACCOUNTADMINのみが付与できる
GRANT EXECUTE ALERT ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
```

アカウント識別子は以下で確認できます。

```sql
SELECT CURRENT_ORGANIZATION_NAME() AS org_name, CURRENT_ACCOUNT_NAME() AS account_name;
```

### Alertのメール通知先アドレスの準備

SnowflakeのEmail Notification Integrationは、そのアカウント上で**メール検証済みのユーザーのアドレス**にしか送信できません。
通知を受け取りたいユーザーでSnowsightにログインし、右上のユーザーメニュー → 「プロフィール」からメールアドレスを登録・検証しておいてください。
検証済みのアドレスを `terraform.tfvars` の `alert_notification_email` に設定します。

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

## 実行

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## Alertの動作確認

`terraform apply` 直後はAlertはRESUME済み(有効)ですが、`SCHEDULE = '1 MINUTE'` で評価されるため反映まで最大1分程度かかります。

このAlertは**エッジ検知**(device_idごとに「直前の行は30度以下、今回は30度超」となった立ち上がりの瞬間だけ)で通知するため、単に30度超のデータを1件INSERTするだけでは、直前の行がすでに30度超だと検知されません(実機のデータが継続的に30度を超えている場合に毎分通知され続けるのを防ぐための設計。詳細は`alert.tf`のコメント参照)。動作確認には「30度以下→30度超」の2行を挿入してください。

1. しきい値をまたぐデータを2件挿入します(`event_timestamp`は前後関係が分かればよいので数秒ずらしています)。

   ```sql
   USE WAREHOUSE IOT_STREAM_ALERT_WH;

   INSERT INTO IOT_STREAM_IOT_DB.ENV_SENSOR.ENV_SENSOR_RAW
     (temperature, humidity, pressure, event_timestamp, device_id)
   VALUES
     (25.0, 50.0, 1013.0, DATE_PART(EPOCH_MILLISECOND, CURRENT_TIMESTAMP()), 'test-device');

   INSERT INTO IOT_STREAM_IOT_DB.ENV_SENSOR.ENV_SENSOR_RAW
     (temperature, humidity, pressure, event_timestamp, device_id)
   VALUES
     (35.0, 50.0, 1013.0, DATE_PART(EPOCH_MILLISECOND, CURRENT_TIMESTAMP()) + 1000, 'test-device');
   ```

2. Alertの実行履歴を確認します(`ALERT_NAME`はスキーマ修飾名で指定、`USE DATABASE`しておくとINFORMATION_SCHEMA関数を素直に呼べます)。

   ```sql
   USE DATABASE IOT_STREAM_IOT_DB;
   USE WAREHOUSE IOT_STREAM_ALERT_WH;

   SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME
   FROM TABLE(INFORMATION_SCHEMA.ALERT_HISTORY(
     SCHEDULED_TIME_RANGE_START => DATEADD('hour', -1, CURRENT_TIMESTAMP()),
     ALERT_NAME => 'IOT_STREAM_IOT_DB.ENV_SENSOR.IOT_STREAM_ENV_SENSOR_TEMPERATURE_ALERT'
   ))
   ORDER BY SCHEDULED_TIME DESC;
   ```

   `TRIGGERED`になっていれば検知成功、`CONDITION_FALSE`なら未検知(まだ実行タイミングが来ていないか、エッジが発生していない)です。

3. ログテーブルに記録されていることを確認します。

   ```sql
   SELECT * FROM IOT_STREAM_IOT_DB.ENV_SENSOR.ENV_SENSOR_TEMPERATURE_ALERT_LOG ORDER BY alerted_at DESC;
   ```

4. `alert_notification_email` で指定したアドレスに、`DEVICE_ID=test-deviceの温度が30度を超えました。` という本文の通知メールが届いていることを確認します。

### 詰まりどころ

- **Alertを`terraform apply`で作り直す(=`execute`のSQL文言を変更する)たびに、Alertは一度SUSPENDEDな状態でCREATEされ直します。** `SNOWFLAKE.ALERT.LAST_SUCCESSFUL_SCHEDULED_TIME()`は「前回成功した実行時刻」が無い初回実行時には非常に古い時刻を返すため、対策なしだと初回実行でテーブルの全履歴分を一括検知・通知してしまいます(実機データが閾値付近で細かく上下する場合は特に顕著)。`alert.tf`では`GREATEST(...)`で下限を「最大5分前」にクランプすることでこれを防いでいます。
- **RESUME用の`snowflake_execute`リソースは、Alert本体が置き換わってもSQL文言が変わらなければ再実行されません。** `alert.tf`ではAlert本体のリソースIDをコメントとして埋め込み、置き換えのたびに強制的に再実行されるようにしています。

## 注意事項

- 本リポジトリはpublicです。証明書・秘密鍵・`*.tfvars`・`*.tfstate` は `.gitignore` で除外していますが、コミット前に必ず `git status` / `git diff --cached` で機密情報が含まれていないか確認してください。
- `terraform apply` はAWS・Snowflake双方で実際にリソースを作成し、課金が発生します。不要になったら `terraform destroy` してください。
