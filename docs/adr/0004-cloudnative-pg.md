# ADR 0004 — CloudNativePG em vez de StatefulSet ou chart Bitnami

**Status:** aceito

## Contexto

A aplicação precisa de PostgreSQL. O requisito de resiliência pede que o
ambiente sobreviva à perda de um componente — e um banco é o componente mais
difícil de tornar resiliente.

## Decisão

CloudNativePG, `instances: 3`, `primaryUpdateStrategy: unsupervised`,
`enableSuperuserAccess: false`, credenciais vindas do Secret basic-auth
produzido pelo ESO.

## Consequências

- **Failover automático demonstrável**: matar o pod primário e ver o operator
  promover uma réplica e reapontar o Service `-rw` em segundos. Isso é
  resiliência que dá para mostrar, não afirmar.
- A aplicação aponta para o Service `-rw`, então o failover não exige mudança de
  configuração.
- `spec.managed.roles` reconcilia a senha continuamente. Sem isso, `bootstrap.
  initdb` rodaria uma vez só e uma rotação futura no Vault atualizaria o Secret
  sem tocar no banco — a aplicação passaria a mandar a senha nova para um role
  com a senha antiga. Outage total, causa não óbvia.
- Custa ~1 GB de RAM a mais que uma instância única. Se a máquina de quem avalia
  for apertada, `postgres.instances: 1` é o primeiro corte.
- **Ser honesto na apresentação:** três instâncias num único host, com PVs
  `local-path` que são node-affine, não é HA de verdade. É a topologia correta
  demonstrada num substrato que não a sustenta.

## Alternativas descartadas

**StatefulSet escrito à mão.** Entrega o mesmo pod rodando. Não entrega
failover, backup, nem reconciliação de credencial — e escrever isso à mão é
reescrever um operator pior.

**Chart do Bitnami.** Era o caminho padrão até 2025, quando a Broadcom moveu as
imagens públicas para um catálogo restrito. Um chart cuja imagem pode
desaparecer não serve para um ambiente que precisa subir daqui a seis meses.

**Postgres gerenciado em nuvem.** Quebra a auto-suficiência e custa dinheiro.
