# ADR 0001 — Argo CD como motor de GitOps

**Status:** aceito

## Contexto

Nada aqui exige GitOps para funcionar. A escolha é deliberada: GitOps é prática
comum em times de plataforma maduros e responde diretamente ao requisito de
deployment automatizado. Argo CD e Flux são as duas opções sérias.

## Decisão

Argo CD, com App-of-Apps, auto-sync e self-heal habilitados.

## Consequências

- A UI mostra drift, histórico de sync e a árvore de recursos — o que torna a
  reconciliação **demonstrável ao vivo**, e não uma afirmação de slide.
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
tira da apresentação a demonstração mais forte que existe — editar um recurso na
mão e ver o self-heal revertê-lo em segundos.

**Nenhum GitOps, só `helm upgrade` no CI.** Atende ao requisito na letra, e
falha no espírito: o estado do cluster deixa de ser derivável do Git, e drift
manual passa a ser invisível.
