# ADR 0001 — Argo CD como motor de GitOps

**Status:** aceito

## Contexto

Nada aqui exige GitOps para funcionar. A escolha é deliberada: GitOps é prática
comum em times de plataforma maduros e responde diretamente à necessidade de
deployment automatizado, com o estado do cluster derivável do Git. Argo CD e
Flux são as duas opções sérias.

## Decisão

Argo CD, com App-of-Apps, auto-sync e self-heal habilitados.

## Consequências

- A UI mostra drift, histórico de sync e a árvore de recursos — o que torna a
  reconciliação **observável em tempo real** durante troubleshooting, em vez de
  algo que só se infere pelos logs.
- `Application` como CRD deixa a árvore de dependências explícita em YAML;
  sync waves ordenam operators antes dos CRs deles.
- Custa mais recursos que o Flux (vários controllers + servidor de API + UI).
  Num k3d de 4 nós isso é aceitável.
- Um segundo modo de falha: um `Application` mal formado fica `Unknown` sem
  aplicar nada. Mitigado com `syncPolicy.retry` e backoff exponencial em todas.

## Alternativas descartadas

**Flux.** Mais leve, mais unixy, e o `image-reflector`/`image-automation`
resolveria o bump de imagem sem CI. Descartado por dois motivos: o time usa Argo
CD oficialmente (Flux só como ferramenta auxiliar interna), e a ausência de UI
reduz a visibilidade operacional do time sobre drift e histórico de sync — o
cenário mais comum de troubleshooting é justamente entender por que um recurso
foi editado manualmente e revertido pelo self-heal.

**Nenhum GitOps, só `helm upgrade` no CI.** Automatiza o deploy, mas falha no
espírito da coisa: o estado do cluster deixa de ser derivável do Git, e drift
manual passa a ser invisível.
