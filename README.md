# stream-iot-data-to-snowflake

M5Stack(ENV3ユニット)で計測した温度・湿度・気圧データを、AWS IoT Core → Kinesis Data Firehose → Snowpipe Streaming 経由でSnowflakeへストリーミング・蓄積するためのTerraform構成です。
蓄積したデータはDynamic Tableでdevice_id・1時間単位に集計し、1時間毎の平均値を保持します。

構築の過程は以下の記事にまとめています。

- (執筆中)IoTデバイスで収集したデータをAWS経由でSnowflakeへ配信・蓄積する方法
- (執筆中)Snowflake Dynamic tablesを使ってIoTデバイスから収集したデータをELTする

## 構成

```
M5Stack(ENV3) --MQTT/TLS--> AWS IoT Core --IoT Rule--> Kinesis Data Firehose --Snowpipe Streaming--> Snowflake(ENV_SENSOR_RAW) --Dynamic Table--> ENV_SENSOR_HOURLY_AVG
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

## 実行

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

## 注意事項

- 本リポジトリはpublicです。証明書・秘密鍵・`*.tfvars`・`*.tfstate` は `.gitignore` で除外していますが、コミット前に必ず `git status` / `git diff --cached` で機密情報が含まれていないか確認してください。
- `terraform apply` はAWS・Snowflake双方で実際にリソースを作成し、課金が発生します。不要になったら `terraform destroy` してください。
