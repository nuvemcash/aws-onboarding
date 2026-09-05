# nuvem.cash — Onboarding AWS (template público)

Template CloudFormation **público e genérico** usado pelo onboarding "um clique" do
[nuvem.cash](https://nuvem.cash) para conectar uma conta AWS.

Ao ser aplicado na **management account** da sua Organization (região `us-east-1`), ele
cria, de forma **somente leitura**:

- um bucket S3 privado (`nuvemcash-focus-<account-id>`), criptografado (SSE-S3) e com
  acesso público bloqueado;
- uma bucket policy que autoriza só o serviço `bcm-data-exports.amazonaws.com` a escrever
  nesse bucket;
- um export **AWS Data Exports** no formato **FOCUS 1.2**, cobrindo a organização inteira,
  em CSV+GZIP, modo *overwrite*;
- uma IAM role read-only (`nuvemcash-collector`, nome determinístico — o ARN é derivável
  do seu account ID) que o nuvem.cash assume via `sts:AssumeRole`, condicionada a um
  **External ID** exclusivo do seu workspace.

Nenhuma credencial de longa duração sai da sua conta: o nuvem.cash acessa via
cross-account role assumption, o padrão que a própria AWS recomenda para acesso de
terceiros.

## Deploy em um clique

Clique no link abaixo (o `ExternalId` é gerado pelo nuvem.cash ao iniciar a conexão do
provider — copie-o da tela de onboarding):

```
https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/quickcreate?templateURL=https://nuvemcash-onboarding.s3.us-east-1.amazonaws.com/latest/template.yaml&stackName=nuvemcash-collector&param_ExternalId=<seu-external-id>
```

Ao final do deploy, copie o output `RoleArn` e cole na tela de conexão do provider AWS no
nuvem.cash.

## Passo a passo manual (fallback do wizard)

Se preferir não rodar um stack de terceiro, os mesmos quatro recursos podem ser criados à
mão, na management account, região `us-east-1`.

### 1. Bucket privado

```bash
aws s3api create-bucket --bucket nuvemcash-focus-<account-id> --region us-east-1
aws s3api put-bucket-encryption --bucket nuvemcash-focus-<account-id> --region us-east-1 \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket nuvemcash-focus-<account-id> --region us-east-1 \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 2. Bucket policy do Data Exports

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EnableAWSDataExportsToWriteToS3",
      "Effect": "Allow",
      "Principal": { "Service": "bcm-data-exports.amazonaws.com" },
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::nuvemcash-focus-<account-id>/*",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "<account-id>" },
        "ArnLike": { "aws:SourceArn": "arn:aws:bcm-data-exports:us-east-1:<account-id>:export/*" }
      }
    }
  ]
}
```

> Use exatamente `ArnLike` em `aws:SourceArn` e `StringEquals` em `aws:SourceAccount` — a
> variante com `StringLike` nos dois campos faz o `CreateExport` falhar.

```bash
aws s3api put-bucket-policy --bucket nuvemcash-focus-<account-id> --region us-east-1 --policy file://policy.json
```

### 3. Export FOCUS 1.2

```bash
aws bcm-data-exports create-export --region us-east-1 --export '{
  "Name": "nuvemcash-focus-1-2",
  "Description": "Export FOCUS 1.2 consumido pelo nuvem.cash (leitura via IAM role cross-account).",
  "DataQuery": {
    "QueryStatement": "SELECT AvailabilityZone, BilledCost, BillingAccountId, BillingAccountName, BillingAccountType, BillingCurrency, BillingPeriodEnd, BillingPeriodStart, CapacityReservationId, CapacityReservationStatus, ChargeCategory, ChargeClass, ChargeDescription, ChargeFrequency, ChargePeriodEnd, ChargePeriodStart, CommitmentDiscountCategory, CommitmentDiscountId, CommitmentDiscountName, CommitmentDiscountQuantity, CommitmentDiscountType, CommitmentDiscountStatus, CommitmentDiscountUnit, ConsumedQuantity, ConsumedUnit, ContractedCost, ContractedUnitPrice, EffectiveCost, InvoiceId, InvoiceIssuerName, ListCost, ListUnitPrice, PricingCategory, PricingCurrency, PricingCurrencyContractedUnitPrice, PricingCurrencyEffectiveCost, PricingCurrencyListUnitPrice, PricingQuantity, PricingUnit, ProviderName, PublisherName, RegionId, RegionName, ResourceId, ResourceName, ResourceType, ServiceCategory, ServiceName, ServiceSubcategory, SkuId, SkuPriceDetails, SkuPriceId, SkuMeter, SubAccountId, SubAccountName, SubAccountType, Tags, x_Discounts, x_Operation, x_ServiceCode FROM FOCUS_1_2_AWS",
    "TableConfigurations": { "FOCUS_1_2_AWS": {} }
  },
  "DestinationConfigurations": {
    "S3Destination": {
      "S3Bucket": "nuvemcash-focus-<account-id>",
      "S3Prefix": "focus",
      "S3Region": "us-east-1",
      "S3OutputConfigurations": {
        "OutputType": "CUSTOM",
        "Format": "TEXT_OR_CSV",
        "Compression": "GZIP",
        "Overwrite": "OVERWRITE_REPORT"
      }
    }
  },
  "RefreshCadence": { "Frequency": "SYNCHRONOUS" }
}'
```

### 4. Role read-only

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::737248776567:root" },
      "Action": "sts:AssumeRole",
      "Condition": { "StringEquals": { "sts:ExternalId": "<seu-external-id>" } }
    }
  ]
}
```

```bash
aws iam create-role --role-name nuvemcash-collector --region us-east-1 --assume-role-policy-document file://trust.json
aws iam put-role-policy --role-name nuvemcash-collector --region us-east-1 --policy-name nuvemcash-collector-readonly --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    { "Sid": "ReadFocusObjects", "Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::nuvemcash-focus-<account-id>/focus/*" },
    { "Sid": "ListFocusBucket", "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::nuvemcash-focus-<account-id>" },
    { "Sid": "ReadCostExplorer", "Effect": "Allow", "Action": ["ce:GetCostAndUsage"], "Resource": "*" }
  ]
}'
```

> O `Resource` de `ReadFocusObjects` acima usa o prefixo `focus/` do `create-export` do
> passo 3 — se você mudar o `S3Prefix` lá, ajuste este `Resource` junto.

> O principal `arn:aws:iam::737248776567:root` delega o controle de quem pode assumir a
> role para o IAM da própria conta Nuvem.Online — é o padrão AWS para acesso de terceiro e
> sobrevive a rotação ou troca do usuário/role coletor sem exigir redeploy em cada conta
> cliente.

Copie o `Arn` da role criada e cole na tela de conexão do provider AWS no nuvem.cash.

## Alternativa: AWS CloudShell

Se a política da sua organização proíbe aplicar stacks de template de terceiros, rode o
mesmo template pelo CloudShell (management account, região `us-east-1`):

```bash
curl -o template.yaml https://nuvemcash-onboarding.s3.us-east-1.amazonaws.com/latest/template.yaml
aws cloudformation deploy \
  --stack-name nuvemcash-collector \
  --template-file template.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides ExternalId=<seu-external-id> \
  --region us-east-1
aws cloudformation describe-stacks --stack-name nuvemcash-collector --region us-east-1 \
  --query 'Stacks[0].Outputs'
```

## Pré-requisitos de billing

- Aplique o stack na **management account** da Organization, região **`us-east-1`** — Cost
  Explorer e Data Exports só existem lá.
- **Cost Explorer** precisa estar habilitado na conta (o primeiro acesso ao console do Cost
  Explorer já liga); sem isso o `ce:GetCostAndUsage` da role é negado mesmo com o stack em
  `CREATE_COMPLETE`.
- Em **Account settings → Billing and Cost Management**, a opção **"IAM user and role access
  to Billing information"** precisa estar ativada — contas mais antigas nascem com ela
  desligada, e nesse caso a role read-only não enxerga nada de billing.
- A primeira entrega do export FOCUS pode levar **até 24h** depois do deploy. Nesse intervalo
  o bucket fica vazio de propósito — é o comportamento esperado, não uma falha do stack.

## Renovar ou remover

**Renovar/reaplicar:** rode o `deploy` de novo (console ou CLI) com a versão atual do
template — os recursos do **stack** são idempotentes e nada é substituído. Essa garantia
vale só para quem passou pelo CloudFormation: se você criou os recursos manualmente (passo
a passo acima), rodar os mesmos comandos de novo tende a falhar por já existirem (por
exemplo, `aws iam create-role` não é idempotente). **Se você já apagou o stack antes**,
reaplicar exige remover (ou renomear) o bucket `nuvemcash-focus-<account-id>` primeiro: o
nome é determinístico, o bucket sobreviveu ao `delete-stack` por causa do Retain (ver
abaixo) e o `deploy` falha tentando recriar um bucket que já existe.

**Remover:** apague o stack (console ou `aws cloudformation delete-stack --stack-name
nuvemcash-collector --region us-east-1`). Isso remove a role, o export e a bucket policy —
a Nuvem.Online perde acesso imediatamente.

O bucket **não** é removido pelo delete-stack: ele tem `DeletionPolicy`/`UpdateReplacePolicy`
`Retain` de propósito, para o histórico FOCUS já entregue sobreviver mesmo que o stack seja
apagado (sem isso, o delete apagava o histórico do cliente junto, ou travava em
`DELETE_FAILED` com objetos dentro). Se quiser remover o bucket também, esvazie-o e apague-o
à mão depois do delete-stack:

```bash
aws s3 rm s3://nuvemcash-focus-<account-id> --recursive --region us-east-1
aws s3api delete-bucket --bucket nuvemcash-focus-<account-id> --region us-east-1
```

Se criou os recursos manualmente (passo a passo acima), remova na ordem inversa: role →
export (`aws bcm-data-exports delete-export`) → bucket policy → bucket.
