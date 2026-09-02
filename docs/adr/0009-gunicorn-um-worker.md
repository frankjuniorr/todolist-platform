# ADR 0009 — gunicorn com 1 worker e 8 threads

**Status:** aceito

## Contexto

`app.py` chama `db.create_all()` **no import do módulo** (linha 952), não dentro
de um `if __name__`. Com `--workers N`, o gunicorn faz fork e cada worker executa
esse import — N processos correndo `CREATE TABLE IF NOT EXISTS` num banco vazio,
ao mesmo tempo. O resultado é `DuplicateTable` intermitente no primeiro boot:
falha que não reproduz, some no restart e volta no ambiente novo.

## Decisão

`--workers 1 --threads 8 --worker-class gthread`, e escalar **horizontalmente**
pelo HPA.

## Consequências

- A race desaparece dentro do pod. Entre pods ela continuaria possível, mas o
  initContainer que espera o banco autenticar reduz drasticamente a janela, e o
  `CREATE TABLE IF NOT EXISTS` é idempotente no caso comum.
- A carga é I/O-bound (consultas ao Postgres, chamadas à API do Kubernetes), e
  threads atendem isso bem — o GIL é liberado durante I/O.
- **É a resposta mais nativa de Kubernetes**: escalar por réplica, não por
  processo dentro do contêiner. O que o requisito de escalabilidade quer ver é
  exatamente isso.
- Um endpoint CPU-bound saturaria o pod antes do esperado. Não há nenhum nesta
  aplicação.

## Alternativa descartada

`--preload` com `post_fork` chamando `db.engine.dispose()`. Funciona: o
`create_all()` roda uma vez no master, antes do fork. Mas **sem o `dispose()`,
os filhos herdam os sockets do pool do master** e duas requisições simultâneas
corrompem a mesma conexão — um bug pior que o original, e muito mais difícil de
diagnosticar. Não vale a complexidade quando o HPA resolve.
