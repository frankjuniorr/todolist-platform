# ADR 0005 — A unseal key do Vault vive num Secret do próprio cluster

**Status:** aceito, com ressalva explícita

## Contexto

O Vault sela a si mesmo a cada restart do pod. Auto-unseal exige um KMS externo
(AWS KMS, GCP KMS, Azure Key Vault, ou outro Vault). Não há nenhum disponível, e
um ambiente que precisa de intervenção manual depois de um reboot não é
auto-suficiente — que era o requisito.

## Decisão

`vault operator init -key-shares=1 -key-threshold=1`. A unseal key é gravada num
Secret do namespace `vault`, e um Deployment `vault-unsealer` observa o estado do
cofre e o destranca em ~10 s sempre que ele aparece selado.

## Consequências

- O ambiente se recupera sozinho de reboot, de `docker restart`, e de qualquer
  restart do pod. É o que torna o "um comando" verdadeiro depois do primeiro dia.
- **A ressalva, dita em voz alta:** a chave que protege o cofre está guardada no
  mesmo cluster que o cofre protege. Na prática, o Vault fica *tão seguro quanto
  o etcd*. Quem tiver `get secret` no namespace `vault` tem o cofre.
- O auto-unseal de nuvem faz conceitualmente a mesma coisa — delega a raiz de
  confiança a outro sistema. A diferença é que lá o outro sistema é um **domínio
  de confiança diferente**; aqui não existe outro domínio.
- **Reconhecer isso explicitamente vale mais do que fingir que o desenho é
  seguro.** O erro real em engenharia não é ter uma limitação; é não saber que
  ela existe.
- Bônus de demonstração, custo zero: `vault operator seal` e ver o ambiente se
  recuperar sozinho.

## Detalhe de implementação que custou tempo

O unsealer aponta para `vault-0.vault-internal`, o Service **headless**, não para
o Service `vault`. Enquanto selado, o pod não fica `Ready`, e um Service comum
remove pods não prontos dos seus endpoints — o unsealer ficaria sem conseguir
alcançar exatamente o Vault que ele existe para destrancar. O `vault-internal`
tem `publishNotReadyAddresses: true`.

Pelo mesmo motivo, o `helm_release` do Vault usa `wait = false`: o readiness
probe do chart é `vault status`, que retorna exit 2 enquanto selado. Com
`wait = true`, o `terraform apply` ficaria preso até o timeout esperando um
unseal que o Ansible ainda não teve chance de fazer.
