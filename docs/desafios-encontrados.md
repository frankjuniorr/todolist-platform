# Desafios encontrados

Anotado enquanto acontecia, não reconstruído de memória no fim. Cada item aqui
custou tempo real, e é a diferença entre quem operou o sistema e quem copiou um
template.

## 1. O deadlock do readiness do Vault

O chart do Vault usa `vault status` como readiness probe, e `vault status`
retorna exit 2 enquanto o cofre está selado. O cofre só é destrancado pelo
Ansible, que roda **depois** do Terraform.

Com `wait = true` no `helm_release`, o `terraform apply` ficava preso até o
timeout esperando um pod ficar `Ready`, e o pod nunca ficaria `Ready` porque
quem o destrancaria estava bloqueado esperando o `terraform apply` terminar.
Deadlock literal.

Solução: `wait = false`, e o Ansible espera `phase=Running`, não
`condition=Ready`. Pela mesma razão, o Vault **não pode** ser uma `Application`
do Argo CD — o StatefulSet ficaria 0/1, a Application ficaria `Progressing`, e a
wave nunca avançaria.

## 2. O unsealer não alcançava o Vault

Consequência do item anterior, e mais sutil. O unsealer apontava para o Service
`vault`. Enquanto selado, o pod não fica `Ready` — e um Service comum remove
pods não prontos dos seus endpoints. O unsealer ficava sem conseguir alcançar
exatamente o Vault que ele existe para destrancar.

Solução: apontar para `vault-0.vault-internal`, o Service headless do chart, que
tem `publishNotReadyAddresses: true`.

## 3. Um erro de ordenação no meu próprio plano

O plano original colocava o `ClusterIssuer` self-signed na wave -20, junto com
os namespaces. Impossível: o CRD `ClusterIssuer` só passa a existir quando o
cert-manager instala, na wave -15. Aplicar o issuer antes falha com
`no matches for kind "ClusterIssuer"`.

Descoberto ao escrever os manifests, não ao rodá-los. A tabela de waves foi
corrigida: -20 namespaces, -15 cert-manager, -12 issuers.

## 4. `checksum/config` não funciona com Secret vindo do ESO

O truque padrão do Helm para reiniciar pods quando a configuração muda é uma
anotação `checksum/config` calculada sobre o conteúdo do Secret. Aqui o Secret é
criado pelo ESO **em runtime** — o Helm não conhece o conteúdo no momento de
renderizar, e o checksum nunca mudaria.

Solução: Stakater Reloader, com anotação explícita ao invés de `auto: true`.

Efeito colateral que quase virou um bug: se o `template` do `ExternalSecret`
tivesse qualquer coisa não determinística, o Secret seria reescrito a cada
refresh e o Reloader dispararia **um rollout por `refreshInterval`**.

## 5. `ttlSecondsAfterFinished` apagando o histórico

A tela `/cleanup/status` é construída lendo os **pods** dos Jobs antigos e os
logs deles. `ttlSecondsAfterFinished` faz o TTL controller apagar Job e pods
independentemente de `successfulJobsHistoryLimit` — e a tela fica vazia sem
nenhum erro.

O campo foi omitido de propósito, com comentário no manifesto explicando por quê.
Sem o comentário, alguém "limpa" isso em três meses.

## 6. O fallback silencioso de `_config()`

```python
except OSError:
    logging.getLogger(__name__).exception('failed to read %s', path)
```

O `FileNotFoundError` é capturado **sem log** e cai no fallback. Se o arquivo do
secret existir mas não for legível — `defaultMode` errado, `fsGroup` que não bate
com o GID da imagem — `DB_PASSWORD` vira string vazia, e o erro que aparece é
`password authentication failed`.

Diagnóstico enganoso: aponta para a senha, e o problema é permissão de arquivo.
Virou um teste de contrato em `tests/test_smoke.py`, para que a regressão seja
detectada no CI e não em produção.

## 7. `fs.inotify.max_user_instances`

O default do Ubuntu é 128. Quatro nós k3s mais Argo CD, Vault, ESO e CNPG
estouram isso de forma confiável. O sintoma não aponta para a causa: "too many
open files" em componentes aleatórios, k3s reiniciando sozinho, pods presos em
`ContainerCreating`.

**É a causa número 1 de "funciona na minha máquina"** neste tipo de ambiente.
Tratado no `setup.sh` e revalidado no `preflight`, com persistência em
`/etc/sysctl.d/`.

## 8. Placeholder de repositório que não podia ser resolvido em runtime

A primeira versão substituía `PLACEHOLDER_REPO_URL` no `root-app.yaml` durante o
playbook. Funcionava para o root — e falhava para todos os `Application` filhos,
porque o Argo CD os lê **direto do Git**. Uma substituição feita na máquina local
nunca chegaria neles.

Solução: `just configure`, que grava a URL nos arquivos uma vez, e o resultado é
commitado. O `preflight` falha se sobrar qualquer placeholder.

## 9. Pin de GitHub Actions por SHA

A boa prática é fixar actions por SHA de commit, não por tag. Não é possível
inventar um SHA — um valor errado quebra o workflow com um erro que parece rede.

Solução: fixar por tag e deixar o Renovate converter para SHA no primeiro PR,
com o preset `helpers:pinGitHubActionDigests`. A prática é aplicada; só não é
aplicada por adivinhação.
