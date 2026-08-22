# stream-iot-data-to-snowflake

M5Stack(ENV3ユニット)で計測した温度・湿度・気圧データを、AWS IoT Core → Kinesis Data Firehose → Snowpipe Streaming 経由でSnowflakeへストリーミング・蓄積するためのTerraform構成です。
蓄積したデータはDynamic Tableでdevice_id・1時間単位に集計し、1時間毎の平均値を保持します。

さらに、Amazon RDS(PostgreSQL)に持たせたセンサーのマスターデータ(センサーID・名前・設置場所)を Openflow Connector for PostgreSQL でSnowflakeに取り込み、Dynamic TableでJOINすることで「センサー値+名前+設置場所」を1つのテーブルに集約します。

構築の過程は以下の記事にまとめています。

- (執筆中)IoTデバイスで収集したデータをAWS経由でSnowflakeへ配信・蓄積する方法
- (執筆中)Snowflake Dynamic tablesを使ってIoTデバイスから収集したデータをELTする
- (執筆中)Openflow Connector for PostgreSQLでRDSのマスターデータをSnowflakeに取り込む

## 構成

```
M5Stack(ENV3) --MQTT/TLS--> AWS IoT Core --IoT Rule--> Kinesis Data Firehose --Snowpipe Streaming--> Snowflake(ENV_SENSOR_RAW) --Dynamic Table--> ENV_SENSOR_HOURLY_AVG
                                                                                                                                                          |
Amazon RDS(PostgreSQL: sensors) --Openflow Connector for PostgreSQL--> Snowflake(SENSOR_MASTER.SENSORS)                                                 |
                                          |                                                                                                              |
                                          +-------------------------------------- Dynamic Table(JOIN) -------------------------------------------------+
                                                                                          |
                                                                                          v
                                                                          ENV_SENSOR_HOURLY_AVG_ENRICHED
```

デバイス側のソースコードは https://github.com/yuuu/aws-m5stack-iot-handson-book-site/tree/main/device を利用しています。

## ディレクトリ構成

```
terraform/
├── versions.tf              # Terraform / provider バージョン制約
├── providers.tf             # aws / snowflake provider設定
├── variables.tf
├── iot.tf                   # AWS IoT Core(Thing, Policy, Topic Rule) ※証明書自体はTerraform管理外
├── firehose.tf              # Kinesis Data Firehose(Snowflake destination), S3, IAM
├── snowflake.tf              # Snowflake側のDatabase/Schema/Table/Role/Service User
├── dynamic_table.tf          # 1時間毎の集計用Warehouse・Dynamic Table
├── rds.tf                    # センサーマスター用RDS(PostgreSQL)、SG、パラメータグループ
├── sql/sensors.sql           # sensorsテーブル・publication作成SQL(psqlで手動実行。Terraform管理外)
├── sensor_master.tf          # Openflow Connector for PostgreSQL用のWarehouse/Role/User/Network Rule/EAI
├── egress_ip_sync.tf         # SnowflakeのEgress IPをRDSのSGへ自動同期するAWS Lambda + EventBridge
├── lambda/egress_ip_sync.py  # 上記Lambdaの本体(cryptography/pyjwtでキーペアJWTを生成)
├── dynamic_table_enriched.tf # ENV_SENSOR_HOURLY_AVGとSENSOR_MASTER.SENSORSをJOINしたDynamic Table
└── outputs.tf
```

## 事前準備

1. AWS CLIプロファイル(`terraform.tfvars` の `aws_profile` で指定)で認証できること
2. Snowflakeに管理用ロール・サービスユーザー(キーペア認証)を用意すること
3. AWS IoT証明書を用意し、そのARNを控えておくこと
4. Snowflakeの静的Egress IPを取得し、RDSのセキュリティグループ初期値(`rds_allowed_cidr_blocks`)として控えておくこと
5. Openflow - Snowflake Deployments のCore Snowflakeセットアップ(`OPENFLOW_ADMIN`ロールの作成など)を完了しておくこと
6. `pip`(Python3)が使えること(`egress_ip_sync.tf` がLambda用の依存パッケージをビルドするために使用)

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
-- Openflow用のExternal Access Integration(egress_ip_sync.tf, sensor_master.tf)の作成に必要
GRANT CREATE INTEGRATION ON ACCOUNT TO ROLE IOT_STREAM_TF_ADMIN_ROLE;
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

### Snowflakeの静的Egress IPの取得

Openflow - Snowflake Deployments(SPCS)からRDSへ接続する際の送信元IPは、Snowflakeが提供する静的Egress IPになります。このIPは90日で失効するため、Snowsight(任意のロール)で以下を実行して現在のCIDRを控え、`terraform.tfvars` の `rds_allowed_cidr_blocks` に設定してください(自分の作業端末のIPも `psql` での手動セットアップ用に追加すること)。

```sql
SELECT SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES();
```

この初期値は最初の `terraform apply` にのみ使われます。以降は `egress_ip_sync.tf` で作成するAWS Lambda(EventBridgeで週次起動)がこの関数を再実行し、RDSのセキュリティグループを自動的に最新のIPレンジへ同期します。

このLambdaはSnowflakeへの認証にキーペア(RSA)+ JWTを使い、SGを書き換える権限はLambdaの実行ロール(IAMロール)側だけに持たせています。Snowflake側の認証情報(秘密鍵)は「`SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES()`を呼べるだけ」の最小権限ユーザーのものなので、万一SSM Parameter Store経由で漏洩してもAWSリソースには波及しません(Snowflake -> AWSではなく、あえてAWS -> Snowflakeの向きにしている理由です)。Programmatic Access Tokenではなくキーペアを選んでいるのは、PATには有効期限があり定期的な再発行が必要になるのに対し、キーペア自体には有効期限がなく運用の手間が増えないためです。

### Openflow - Snowflake Deployments の準備(Core Snowflake)

Openflowのデプロイメント/ランタイム作成はSnowsight UIから行うため、Terraformの対象外です。ACCOUNTADMINロールで以下を一度だけ実行し、Openflow管理用のロールとユーザーを準備してください(詳細は[Set up Openflow - Snowflake Deployment: Core Snowflake](https://docs.snowflake.com/en/user-guide/data-integration/openflow/setup-openflow-spcs-sf)を参照)。

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS OPENFLOW_ADMIN;
GRANT ROLE OPENFLOW_ADMIN TO USER <openflowを操作するユーザー>;

-- ACCOUNTADMINをデフォルトロールに持つユーザーはOpenflowランタイムにログインできないため、別ロールを既定にする
ALTER USER <openflowを操作するユーザー> SET DEFAULT_ROLE = OPENFLOW_ADMIN;
ALTER USER <openflowを操作するユーザー> SET DEFAULT_SECONDARY_ROLES = ('ALL');

GRANT CREATE OPENFLOW DATA PLANE INTEGRATION ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE OPENFLOW RUNTIME INTEGRATION ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
GRANT CREATE COMPUTE POOL ON ACCOUNT TO ROLE OPENFLOW_ADMIN;
```

## 実行

`SENSOR_MASTER.SENSORS` テーブルはOpenflow Connector for PostgreSQLが初回スナップショット時に作成するため、`ENV_SENSOR_HOURLY_AVG_ENRICHED` Dynamic Tableは1回目の`apply`では作成できません。以下のように2段階で実行してください。

### 1. 基盤リソースの作成(1回目のapply)

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

これでAWS(IoT Core, Firehose, RDS, Egress IP同期用Lambda/EventBridge)とSnowflake(ENV_SENSOR_RAW, ENV_SENSOR_HOURLY_AVG, SENSOR_MASTERスキーマ, Openflow用Warehouse/Role/User/Network Rule/EAI, Egress IP取得用の最小権限ユーザー)が作成されます。`ENV_SENSOR_HOURLY_AVG_ENRICHED` はまだ作成されません(SENSOR_MASTER.SENSORSが存在しないためエラーになります。エラーが出た場合はそのまま次のステップに進んでください)。

### 2. sensorsテーブルの作成(RDS)

`terraform apply` 完了後、`terraform output` でRDSのエンドポイントを確認し、`terraform/sql/sensors.sql` を参考にマスターユーザーで手動実行します。

```bash
terraform output rds_endpoint
terraform output -raw rds_master_password

psql "host=<rds_endpoint> port=5432 dbname=<sensors_db_name> user=<postgres_master_username> sslmode=require" \
  -f sql/sensors.sql
```

`sql/sensors.sql` 内の `REPLACE_ME_*` は実際の値(デバイスのchip-id、レプリケーションユーザーのパスワードなど)に置き換えてから実行してください。

### 3. Openflow - Snowflake Deployment / Runtime の作成(Snowsight UI)

現時点ではDeployment/Runtime作成、コネクタのインストール・設定はSnowsight UI操作のみでTerraform化できません。

1. Snowsight「Ingestion » Openflow」からDeploymentを作成
2. Runtimeを作成する際、`sensor_master.tf` で作成した `IOT_STREAM_RDS_POSTGRES_EAI`(External Access Integration)をアタッチ
3. 「Openflow Connector for PostgreSQL」をインストールし、以下を指定して設定
   - 接続先: RDSのエンドポイント(`terraform output rds_endpoint`)、`sql/sensors.sql` で作成した `openflow_connector` ユーザー、`openflow_publication`
   - 接続先Snowflake: `IOT_STREAM_OPENFLOW_INGEST_USER`(キーペア認証)、`IOT_STREAM_OPENFLOW_INGEST_ROLE`、`IOT_STREAM_OPENFLOW_WH`、`IOT_STREAM_IOT_DB.SENSOR_MASTER`
4. コネクタを起動し、初回スナップショットが完了して `SENSOR_MASTER.SENSORS` テーブルが作成されたことをSnowsightで確認

### 4. JOINしたDynamic Tableの作成(2回目のapply)

```bash
terraform apply
```

`SENSOR_MASTER.SENSORS` が存在する状態で再度applyすることで、`ENV_SENSOR_HOURLY_AVG_ENRICHED`(センサー値+名前+設置場所)が作成されます。

## 注意事項

- 本リポジトリはpublicです。証明書・秘密鍵・`*.tfvars`・`*.tfstate` は `.gitignore` で除外していますが、コミット前に必ず `git status` / `git diff --cached` で機密情報が含まれていないか確認してください。
- `terraform apply` はAWS・Snowflake双方で実際にリソースを作成し、課金が発生します。不要になったら `terraform destroy` してください。
- RDSインスタンスはデモ用途のため `publicly_accessible = true` としています。セキュリティグループで5432番ポートへのアクセス元をSnowflakeの静的Egress IPと自分の作業端末IPに限定していますが、本番用途ではAWS PrivateLink(Business Critical Edition限定)等の非公開接続を検討してください。
- Snowflakeの静的Egress IPは90日で失効します。初回の `rds_allowed_cidr_blocks` は手動設定が必要ですが、以降は `egress_ip_sync.tf` のAWS Lambda(EventBridgeで週次起動)がRDSのセキュリティグループを自動的に最新のIPレンジへ同期します。実行状況はCloudWatch Logs(`/aws/lambda/<project_name>-egress-ip-sync`)から確認できます。
- `egress_ip_sync.tf` のLambdaパッケージ(cryptography/pyjwt)は `terraform apply` 実行時に `pip install --platform manylinux2014_x86_64 ...` でビルドされます。ビルドを実行する環境にインターネット接続と `pip`(python3)が必要です。
- Openflow Connector for PostgreSQLの同期スケジュール(マージ頻度)はコネクタ側の設定に依存します。`ENV_SENSOR_HOURLY_AVG_ENRICHED` のTARGET_LAGだけでなく、コネクタ側のマージスケジュールも確認してください。
