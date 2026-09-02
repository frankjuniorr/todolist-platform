# ADR 0002 — HashiCorp Vault no cluster + External Secrets Operator

**Status:** aceito · **Este é o item de maior risco da entrega**

## Contexto

A aplicação precisa de seis secrets. Duas exigências: o repositório precisa ser
publicável com segurança, e o cluster precisa de uma gestão de secrets que não
seja "um Secret aplicado na mão".

## Decisão

Vault standalone no cluster (file storage em PVC) como gerenciador de secrets, e
o External Secrets Operator lendo dele por `auth/kubernetes` para materializar
os Secrets do Kubernetes.

## Consequências

- **Zero dependência externa e zero custo.** O cluster continua auto-suficiente:
  não precisa de conta em nuvem nem de internet além do pull das imagens.
- Nenhum Secret do Kubernetes entra no Git — nem cifrado.
- Rotação vira uma operação real: escreve no Vault, o ESO reescreve o Secret, o
  Reloader reinicia o Deployment.
- **O Vault re-sela a cada restart do pod.** Sem KMS, não há auto-unseal — daí
  o ADR 0005.
- É a peça com mais superfícies de falha silenciosa: mismatch de audience no
  TokenRequest, política errada, caminho kv-v1 vs kv-v2. Um dia inteiro de
  orçamento reservado, com checkpoint go/no-go.

## Alternativas descartadas

**1Password Connect Operator.** Tenho conta. O problema é conceitual: o Connect
precisa de um token e de um arquivo de credenciais **injetados antes** — ou seja,
um secret de bootstrap para o sistema que existe para gerenciar secrets. O
chicken-and-egg não some, só muda de lugar. Some ainda a dependência de internet
e de uma conta que quem avalia não tem.

**Sealed Secrets.** Resolve o problema do Git com elegância e quase sem custo.
Descartado porque cifra *para um cluster específico*: a chave privada vive no
controller, e recriar o cluster invalida todos os SealedSecrets já commitados —
exatamente o oposto da reprodutibilidade que o R1 pede. É o plano B declarado.

**SOPS + age (com KSOPS).** Bom, portátil, e o plano B real se o Vault falhar no
checkpoint. Perde porque não é um gerenciador de secrets: não tem rotação, nem
versionamento, nem auditoria, nem TTL — é cifragem de arquivo.

**Secrets do Kubernetes aplicados na mão.** Honesto sobre a POC, mas deixa de
demonstrar gestão de secrets de nível produção.
