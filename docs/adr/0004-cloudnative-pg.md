# ADR 0004 — CloudNativePG em vez de StatefulSet ou chart Bitnami

**Status:** aceito

## Contexto

A aplicação precisa de PostgreSQL. A plataforma precisa sobreviver à perda de
um componente sem intervenção manual — e um banco é o componente mais difícil
de tornar resiliente.

## Decisão

CloudNativePG, `instances: 3`, `primaryUpdateStrategy: unsupervised`,
`enableSuperuserAccess: false`, credenciais vindas do Secret basic-auth
produzido pelo ESO.

## Consequências

- **Failover automático verificável**: matar o pod primário e observar o
  operator promover uma réplica e reapontar o Service `-rw` em segundos.
- A aplicação aponta para o Service `-rw`, então o failover não exige mudança de
  configuração.
- `spec.managed.roles` reconcilia a senha continuamente. Sem isso, `bootstrap.
  initdb` rodaria uma vez só e uma rotação futura no Vault atualizaria o Secret
  sem tocar no banco — a aplicação passaria a mandar a senha nova para um role
  com a senha antiga. Outage total, causa não óbvia.
- Custa ~1 GB de RAM a mais que uma instância única. Em hosts com recursos
  limitados, `postgres.instances: 1` é o primeiro corte.
- **Limitação a registrar:** três instâncias num único host, com PVs
  `local-path` que são node-affine, não é HA de verdade — se o host cair, as
  três instâncias caem juntas. É a topologia correta rodando sobre um substrato
  de storage que não a sustenta plenamente; em produção isso exige storage
  replicado entre hosts (Longhorn, Ceph, ou um serviço gerenciado).

## Alternativas descartadas

**StatefulSet escrito à mão.** Entrega o mesmo pod rodando. Não entrega
failover, backup, nem reconciliação de credencial — e escrever isso à mão é
reescrever um operator pior.

**Chart do Bitnami.** Era o caminho padrão até 2025, quando a Broadcom moveu as
imagens públicas para um catálogo restrito. Um chart cuja imagem pode
desaparecer não serve para um ambiente que precisa subir daqui a seis meses.

**Postgres gerenciado em nuvem.** Quebra a auto-suficiência e custa dinheiro.
