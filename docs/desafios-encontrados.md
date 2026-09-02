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

---

Os itens abaixo só apareceram na primeira execução real de ponta a ponta —
`just up` completo, do zero, seguido do CI dos dois repositórios rodando de
verdade. Nada disso é hipotético; cada um quebrou, foi diagnosticado ao vivo, e
a correção foi validada antes de seguir para o próximo.

## 10. DNS quebra dentro do cluster — o proxy embutido do Docker não responde

O sintoma apareceu tarde e longe da causa: o Argo CD ficava para sempre com 1
`Application` (a `root`) e nunca sincronizava as filhas, com o erro `dial tcp:
lookup github.com ... server misbehaving`. O CoreDNS do k3s nasce com
`forward . /etc/resolv.conf`, que dentro do container aponta para o proxy de
DNS embutido do Docker (o gateway da rede, ex. `172.19.0.1:53`). Nesta máquina
esse proxy simplesmente não respondia — `nslookup` direto contra ele devolvia
`Connection refused`, e os resolvedores reais do host (roteador/AdGuardHome da
LAN) não aceitavam consulta vinda da sub-rede do Docker (`connection timed
out`). Só um resolvedor público (`1.1.1.1`) respondia.

**Primeira tentativa, descartada:** `kubectl patch` no ConfigMap `coredns`
depois do cluster criado, trocando `forward` para `1.1.1.1 8.8.8.8`. Parece
funcionar — um teste imediato confirma a resolução —, mas o k3s tem um
"deploy controller" próprio (`objectset.rio.cattle.io`) que reconcilia os
addons núcleo continuamente. Na primeira vez que o Deployment do `coredns`
reinicia, o patch manual é **revertido silenciosamente** de volta ao padrão.
O teste "funcionou" só porque rodou antes da próxima reconciliação.

Solução real: configurar o `--resolv-conf` do próprio k3s **na criação do
cluster** (`k3d cluster create --volume .../resolv.conf:/etc/k3d-resolv.conf@server:*;agent:*
--k3s-arg=--resolv-conf=/etc/k3d-resolv.conf@server:*;agent:*`), montando um
arquivo fixo com resolvedores públicos. Isso configura o kubelet para servir
esse conteúdo como `/etc/resolv.conf` de qualquer pod com `dnsPolicy: Default`
— inclusive o próprio CoreDNS —, e sobrevive a qualquer restart porque não é
um patch por cima, é a fonte que o k3s usa desde o início.

Detalhe de sintaxe que custou uma tentativa extra: `--k3s-arg` e `--volume` têm
formatos de node-filter *diferentes* apesar de parecidos — `--volume` aceita
`@filtro1;filtro2`, mas `--k3s-arg` exige um `@` extra por filtro adicional
(`@filtro1;@filtro2`) segundo o `--help`; na prática, mesmo o formato do
`--help` foi rejeitado pelo `k3d` instalado (`only one unescaped '@' allowed`),
e o que funcionou de verdade foi o formato de `--volume` (um único `@`,
filtros separados por `;` sem `@` extra) aplicado também ao `--k3s-arg`.

## 11. O chart oficial do Reloader não é compatível com Pod Security "restricted"

O namespace `todolist` reforça `pod-security.kubernetes.io/enforce: restricted`.
O Deployment do Reloader (chart `stakater/reloader`) nunca conseguia criar um
único pod: `ReplicaFailure: FailedCreate`, `violates PodSecurity "restricted":
allowPrivilegeEscalation != false ... unrestricted capabilities`. O chart tem
um `containerSecurityContext: {}` vazio por padrão — quem instala precisa
preenchê-lo. Solução: `reloader.deployment.containerSecurityContext:
{allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}` no
`valuesObject` do Application. Vale generalizar: **todo chart de terceiro
instalado num namespace `restricted` precisa ser auditado por este campo
especificamente** — `helm lint`/`kubeconform`/`kube-linter` não pegam isso
porque o problema só existe na combinação chart+namespace, não no chart
isolado.

## 12. O PDB da aplicação também protegia os pods do CronJob de limpeza

`kubectl describe pdb todolist` mostrava `Failed to calculate the number of
expected pods: jobs.batch does not implement the scale subresource`, e a
Application ficava `Degraded`. Causa: o seletor do PDB usa
`todolist.selectorLabels` (nome + instância), que é exatamente o mesmo
subconjunto de labels que o pod do `CronJob` de limpeza também carrega — e
como o `ttlSecondsAfterFinished` é omitido de propósito (item 5 acima), esses
pods ficam vivos tempo suficiente para o PDB tentar protegê-los. O controller
do PDB, ao encontrar um pod cujo dono é um `Job`, tenta consultar o
subresource `scale` do `Job` para saber quantas réplicas esperar — e `Job` não
tem esse subresource. Solução: rotular os pods do Deployment com
`app.kubernetes.io/component: app` (label extra, não usada no seletor do
próprio Deployment — não é campo imutável) e apertar o seletor do PDB para
exigir esse mesmo componente, excluindo os pods do `Job` sem tocar no seletor
do Deployment.

## 13. CloudNativePG e o mesmo problema do `caBundle`, só que no CR

O `Cluster` do CNPG ficava `OutOfSync` para sempre. Motivo idêntico ao do
`caBundle` (item já conhecido para os webhooks do cert-manager/ESO), só que
desta vez é o **webhook mutante do próprio CNPG** que preenche dezenas de
campos default em `spec.*` (afinidade, `postgresql.conf` inteiro, monitoring,
replicationSlots, os campos extras que o operator adiciona em
`managed.roles[0]`) que o nosso manifesto nunca declarou. `managedFieldsManagers`
não resolve aqui — checado via `kubectl get ... -o jsonpath='{.metadata.managedFields[*].manager}'`,
que mostrou um único manager (`argocd-controller`): o webhook edita a
requisição *antes* dela chegar no etcd, então não sobra um manager separado
para excluir por nome. Solução: `ignoreDifferences` com uma lista explícita de
`jsonPointers` para os campos conhecidos como puramente operator-defaulted.
Trade-off registrado: mudar `postgres.owner` no Git não vai mais re-sincronizar
`managed.roles[0].name` sozinho, porque esse subcaminho está na lista — é uma
troca consciente de fine-grained drift detection por um estado `Synced`
estável, e o campo em questão não deveria mudar em produção de qualquer jeito.

## 14. `vault_password_file` no `ansible.cfg` quebra a promessa de "um comando" na prática

A promessa central do design (seed_secrets gera valores aleatórios quando não
há `vault.yml`) tinha um furo: `ansible.cfg` apontava
`vault_password_file = ../.vault-pass` incondicionalmente. O Ansible falha ao
**iniciar** quando esse arquivo não existe — mesmo que nada no playbook
precise decifrar coisa alguma nesse run. `[ERROR]: The vault password file
... was not found` interrompe tudo antes da primeira task. Solução: tirar
`vault_password_file` do `ansible.cfg` e passar `--vault-password-file`
condicionalmente pelo próprio `Justfile`, só quando o arquivo existe de
verdade.

## 15. `become: true` incondicional no ajuste de inotify pede senha de sudo à toa

A task que eleva `fs.inotify.max_user_instances` sempre usava `become: true`,
mesmo quando o valor já estava correto (o `setup.sh` já cuida disso no Dia -1).
Numa máquina sem sudo sem senha configurado para isso especificamente, o
`just up` trava em `Premature end of stream waiting for become success: sudo:
a password is required` — outra quebra silenciosa da promessa de "sem prompt".
Solução: mapear os valores atuais numa variável e só chamar o módulo com
`become: true` quando o valor lido é de fato menor que o alvo.

## 16. CVE real vendorizada dentro do próprio `pip`, não no `requirements.txt`

O `trivy` da imagem publicada acusou HIGH em `jaraco.context` e `wheel` —
nenhum dos dois está nas dependências da aplicação. Ambos vêm **vendorizados
dentro do próprio `pip`** (todo `pip` carrega cópias internas de
`setuptools`/`wheel`/`msgpack`/etc. para uso próprio, listadas em
`pip/_vendor/vendor.txt`). Atualizar o `pip` não resolve — a versão mais
recente disponível ainda vendoriza um `setuptools` desatualizado o bastante
para acusar CVE. Solução real: `pip uninstall -y pip setuptools wheel` na
imagem final — eles não têm nenhuma função em runtime (o `ENTRYPOINT` é
`gunicorn`, nunca invoca `pip`), então a resposta correta é reduzir a
superfície, não mascarar o scanner. Confirmado que o uninstall roda limpo
(o Python já carregou tudo que precisa em memória) e não deixa rastro.

## 17. `${{ }}` dentro de flow-mapping do YAML não faz parse

`env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} }` quebra o workflow inteiro
antes de qualquer job rodar — GitHub nem consegue ler o `name:` do arquivo (o
workflow aparece na lista como o próprio path, não o nome declarado, e esse
sintoma sozinho já aponta para erro de parse). Causa: os dois `}` finais de
`${{ ... }}` fecham o mapping `{ }` cedo demais, sobrando uma chave
desbalanceada. Solução: mapeamento em bloco em vez de flow-style sempre que o
valor contiver uma expressão do Actions.

## 18. A action `ansible/ansible-lint@v24` instala uma combinação quebrada

A action baixa seu próprio `requirements-lock.txt` do ref `v24` — no momento
em que isso rodou, fixava `ansible-lint==24.12.2` junto de um `ansible-core`
que não tinha mais `ansible.parsing.yaml.constructor`, e o próprio
`ansible-lint` quebrava ao importar (`ModuleNotFoundError`), antes de analisar
uma única linha nossa. *Drift* de versão de uma dependência transitiva de uma
action de terceiro — o tipo de coisa que pinagem explícita evita. Solução:
abandonar a action, instalar `ansible-lint==26.8.0` via `pip` (mesma versão já
validada localmente). Efeito colateral: `ansible-lint` sozinho só traz
`ansible-core`, não a coleção `ansible.posix` que o preflight usa
(`ansible.posix.sysctl`) — localmente nunca aparece porque o `setup.sh`
instala o pacote `ansible` completo, que já vem com ela. Precisou de
`ansible-galaxy collection install ansible.posix` explícito no CI.

## 19. `errexit` e o `&&` que nunca chega a ter sucesso no caminho feliz

O bug mais instrutivo da sessão. `image-bump.yml` tinha
`git diff --exit-code && { echo "digest ja atual"; exit 0; }` como linha solta
num passo `run:`. Passos do Actions usam `bash -e` por padrão. `git diff
--exit-code` devolve `1` quando **há** diferença — o caso normal, o que se
queria processar — e é esse `1`, do lado esquerdo de um `&&` que nunca chega a
rodar o lado direito, que o `-e` usa para abortar o script inteiro. **O
workflow só tinha sucesso no caso em que não havia nada para fazer**; o
caminho feliz de verdade morria ali, antes do `git commit`, sem nenhuma
mensagem que apontasse para a causa. Correção: `if git diff --quiet; then ...
fi` — comandos usados como condição de `if`/`while` são isentos da regra do
`errexit`. Lição generalizada: lógica de shell com controle de fluxo
(condicional, loop) deve virar script externo, nunca ficar inline num `run:`
— só assim dá para rodar `shellcheck` nela e testar fora do CI.

## 20. Duas permissões que o GitHub nega por padrão num repositório novo

Depois do `errexit` corrigido, o `image-bump.yml` ainda falhou duas vezes,
cada vez num degrau de permissão diferente:

- `could not add label: 'automated' not found` — labels não vêm de fábrica
  num `gh repo create`. Corrigido fazendo o próprio script criar o label se
  não existir (`gh label create ... || true`), em vez de depender de alguém
  criar na mão antes da primeira execução.
- `GitHub Actions is not permitted to create or approve pull requests` — é a
  configuração "Allow GitHub Actions to create and approve pull requests"
  (Settings → Actions → General), desligada por padrão desde que o GitHub
  identificou esse vetor de abuso (um workflow comprometido que se
  auto-aprova). Ao contrário do label, este **precisa** ser manual — é uma
  decisão de segurança do dono do repositório, não algo que o próprio
  workflow deveria conseguir ligar sozinho.

## 21. Idempotência do `setup.sh` quebrada por um espaço no JSON

Os checks de versão de `kubectl` e `terraform` em `setup.sh` usavam
`grep -o '"gitVersion":"[^"]*'` (sem espaço depois dos dois-pontos). Só que
`kubectl version --client -o json` e `terraform version -json` formatam com
espaço (`"gitVersion": "v1.31.4"`), então o grep nunca casava, a checagem de
"já está na versão certa" sempre dava falso, e as duas ferramentas eram
**reinstaladas a cada `just setup`**, mesmo já corretas. Silencioso — não
quebra nada visivelmente, só desperdiça banda e tempo, e esconde o verdadeiro
propósito da idempotência anunciada no cabeçalho do script. Corrigido com
`"gitVersion": *"[^"]*` (espaço opcional).
