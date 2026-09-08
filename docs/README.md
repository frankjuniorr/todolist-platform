# Documentação

Índice da documentação detalhada do projeto. O `README.md` na raiz do
repositório dá o resumo; aqui está o aprofundamento, por etapa e por
ferramenta.

| Página | Assunto |
|---|---|
| [Arquitetura](arquitetura.md) | o desenho, e por que a fronteira entre as ferramentas é essa |
| [Bootstrap](bootstrap.md) | o que exatamente acontece durante `just up`, fase a fase |
| [GitOps](gitops.md) | Argo CD, App-of-Apps, sync waves, self-heal |
| [Secrets](secrets.md) | do arquivo cifrado no Git até o arquivo dentro do pod |
| [Banco de dados](banco-de-dados.md) | CloudNativePG, failover e rotação de credencial |
| [Escalabilidade](escalabilidade.md) | HPA, PDB, probes — e o que aqui é teatro |
| [CI/CD](ci-cd.md) | as duas esteiras e como elas se conectam |
| [Decisões](decisoes.md) | índice comentado dos ADRs em `adr/` |

## Os dois repositórios

| Repositório | Conteúdo | Dono conceitual |
|---|---|---|
| `todolist-app` | a aplicação, o Dockerfile, o CI de imagem | time de produto |
| `todolist-platform` | infra, chart, GitOps, automação | time de plataforma |

A interface entre os dois é o **digest da imagem**: o CI da aplicação publica no
GHCR e dispara um bump no repositório de plataforma. Ver [CI/CD](ci-cd.md).

## Stack

| Camada | Escolha |
|---|---|
| Cluster | k3d (k3s em Docker), 1 server + 3 agents, imagem fixada |
| GitOps | Argo CD, padrão App-of-Apps |
| IaC | Terraform (namespaces, Argo CD, Vault) |
| Orquestração de Day-0 | Ansible |
| Empacotamento | Helm (chart próprio) |
| Secret manager | HashiCorp Vault + External Secrets Operator |
| Banco | CloudNativePG (3 instâncias, failover automático) |
| Ingress / TLS | Traefik (embutido no k3s) + cert-manager com CA interna |
| Interface de uso | `just` |

## O que este ambiente não é

Declarado de propósito, porque a alternativa seria enganosa:

- **Não é alta disponibilidade.** Os quatro "nós" são contêineres num único host,
  com um kernel e um daemon do Docker. Os objetos de resiliência estão corretos e
  o comportamento é demonstrável, mas não há tolerância a falha de infraestrutura
  real.
- **Não tem observabilidade.** A aplicação não expõe `/metrics`.
- **Não tem backup.** O CloudNativePG suporta `ScheduledBackup` para object
  storage, e não há bucket disponível neste ambiente.
- **A unseal key do Vault vive num Secret do próprio cluster.** É um trade-off
  consciente, detalhado no [ADR 0005](adr/0005-unseal-key-no-cluster.md).
