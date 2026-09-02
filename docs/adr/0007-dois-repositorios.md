# ADR 0007 — Dois repositórios, ambos públicos

**Status:** aceito

## Contexto

A aplicação já existe num repositório. A plataforma é código novo. Um repo ou dois?

## Decisão

Dois: `todolist-app` (fork, com Dockerfile e CI) e `todolist-platform` (a
entrega principal). Ambos públicos.

## Consequências

- Espelha a separação real entre time de produto e time de plataforma, comum em
  organizações com um time de plataforma dedicado. O ciclo de vida é diferente:
  a aplicação muda por feature, a plataforma muda por decisão de infraestrutura.
- O acoplamento fica explícito e auditável: um `repository_dispatch` carregando
  um digest. Nada de import implícito.
- **Públicos resolve dois chicken-and-egg de uma vez:** o Argo CD não precisa de
  credencial de repositório para ler os manifests, e o cluster não precisa de
  `imagePullSecret` para puxar do GHCR. Num ambiente que precisa subir com um
  comando na máquina de outra pessoa, cada credencial a menos é um modo de falha
  a menos.
- Custa dois CIs para manter e um PAT para o dispatch.

## Alternativas descartadas

**Monorepo.** Mais simples de operar e sem o PAT. Descartado porque apagaria
justamente a fronteira que a entrega quer demonstrar — e porque um push de
código da aplicação dispararia a reconciliação da plataforma, acoplando as duas
esteiras.
