# ADR 0003 — A fronteira entre Ansible, Terraform e Argo CD

**Status:** aceito

## Contexto

Três ferramentas que se sobrepõem. Todas conseguem instalar um Helm chart no
Kubernetes. Usar as três sem uma regra clara produz disputa de propriedade:
dois donos para o mesmo recurso, `OutOfSync` permanente, ou uma ferramenta
removendo o que a outra criou.

## Decisão

Uma regra só, e ela decide todos os casos:

> **Ansible faz o que acontece uma vez. Argo CD faz o que precisa acontecer para
> sempre. Terraform faz o mínimo necessário para o Argo CD existir.**

- **Terraform:** namespaces, Argo CD, Vault. Nada mais.
- **Ansible:** criar o cluster, chamar o Terraform, init/unseal do Vault,
  semear os valores, aplicar o root Application. Tudo isso é evento, não estado.
- **Argo CD:** cert-manager, issuers, ESO, CNPG, Reloader, `ClusterSecretStore`
  e a aplicação. Tudo isso é estado a ser mantido.

## Consequências

- Cada recurso tem exatamente um dono. Não existe recurso disputado.
- O Terraform administra um punhado de objetos; o `tfstate` fica trivial, e
  `just down` pode simplesmente apagá-lo.
- Responde diretamente à pergunta original ("o código principal deve ser Ansible,
  faz sentido?"): **faz, como camada de bootstrap** — não como o motor do
  ambiente. Ansible orquestrando `kubectl apply` continuamente seria um GitOps
  pior, sem reconciliação nem detecção de drift.
- Cria uma ordem obrigatória: o App-of-Apps é o último passo do playbook, quando
  o Vault já responde. Aplicá-lo antes faria o `ExternalSecret` da wave -3
  encontrar um cofre selado.

## Alternativas descartadas

**Terraform instalando tudo.** Vira um segundo GitOps, pior: sem reconciliação
contínua, sem self-heal, e com o `kubernetes_manifest` falhando em *plan time*
para qualquer CRD que ainda não exista.

**Ansible instalando tudo.** Mesmo problema, com o agravante de ser imperativo
por natureza: o estado do cluster passa a depender da ordem em que as tasks
rodaram, não do conteúdo do repositório.
