# stream-iot-data-to-snowflake

M5Stack(ENV3ユニット)で計測した温度・湿度・気圧データを、AWS IoT Core → Kinesis Data Firehose → Snowpipe Streaming 経由でSnowflakeへストリーミング・蓄積するためのTerraform構成です。

構築の過程は以下の記事にまとめています。

- (執筆中)IoTデバイスで収集したデータをAWS経由でSnowflakeへ配信・蓄積する方法

## 構成

```
M5Stack(ENV3) --MQTT/TLS--> AWS IoT Core --IoT Rule--> Kinesis Data Firehose --Snowpipe Streaming--> Snowflake
```

デバイス側のソースコードは https://github.com/yuuu/aws-m5stack-iot-handson-book-site/tree/main/device を利用しています。

## ディレクトリ構成

```
terraform/
├── versions.tf   # Terraform / provider バージョン制約
├── providers.tf  # aws / snowflake provider設定
├── variables.tf
├── iot.tf        # AWS IoT Core(Thing, 証明書, Policy, Topic Rule)
├── firehose.tf   # Kinesis Data Firehose(Snowflake destination), S3, IAM
├── snowflake.tf  # Snowflake側のDatabase/Schema/Table/Role/Service User
└── outputs.tf
```

## 事前準備

1. AWS CLIプロファイル(`terraform.tfvars` の `aws_profile` で指定)で認証できること
2. Snowflakeに管理用ロール・サービスユーザー(キーペア認証)を用意すること

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
CREATE ROLE IF NOT EXISTS TF_ADMIN_ROLE;
GRANT ROLE TF_ADMIN_ROLE TO ROLE SYSADMIN;

CREATE USER IF NOT EXISTS TF_ADMIN_USER
  TYPE = SERVICE
  DEFAULT_ROLE = TF_ADMIN_ROLE
  RSA_PUBLIC_KEY = '<公開鍵の1行文字列>';

GRANT ROLE TF_ADMIN_ROLE TO USER TF_ADMIN_USER;

GRANT CREATE DATABASE ON ACCOUNT TO ROLE TF_ADMIN_ROLE;
GRANT CREATE ROLE ON ACCOUNT TO ROLE TF_ADMIN_ROLE;
GRANT CREATE USER ON ACCOUNT TO ROLE TF_ADMIN_ROLE;
GRANT MANAGE GRANTS ON ACCOUNT TO ROLE TF_ADMIN_ROLE;
```

アカウント識別子は以下で確認できます。

```sql
SELECT CURRENT_ORGANIZATION_NAME() AS org_name, CURRENT_ACCOUNT_NAME() AS account_name;
```

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
