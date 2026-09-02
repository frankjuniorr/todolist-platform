# ADR 0008 — TLS com CA interna emitida pelo cert-manager

**Status:** aceito

## Contexto

O requisito pede acesso pelo navegador. Não pede HTTPS. Mas um ambiente sem TLS
não é um ambiente que alguém colocaria em produção, e o objetivo é demonstrar a
prática correta.

Let's Encrypt não é possível: exige um domínio público e um desafio ACME
resolvível de fora — e o ambiente roda em `localhost`, atrás do NAT de quem
avalia.

## Decisão

cert-manager com uma cadeia de três passos: `ClusterIssuer` self-signed →
`Certificate` de CA raiz → `ClusterIssuer` do tipo `ca`. Hostnames em
`*.localhost`.

## Consequências

- Certificados emitidos e renovados automaticamente, por anotação no `Ingress`.
  A mecânica é idêntica à de produção; só a âncora de confiança muda.
- O navegador mostra aviso, a menos que a CA seja instalada no trust store
  (`just trust-ca`, ou gerar a CA com `mkcert`, que já instala nos stores do
  sistema e do NSS).
- **`*.localhost`, não `nip.io`.** O systemd-resolved do Ubuntu resolve
  `qualquer-coisa.localhost` para 127.0.0.1 nativamente, sem DNS externo.
  `nip.io` e `sslip.io` falham em redes com proteção contra DNS rebinding
  (dnsmasq, pi-hole, resolvers corporativos) — que é um jeito frequente e
  humilhante de uma demonstração morrer.
- Recursos **`Ingress`, não `IngressRoute`** do Traefik: o ingress-shim do
  cert-manager só observa `Ingress`, então a anotação emite o certificado
  sozinha. Com `IngressRoute` seria um `Certificate` manual por host — e o
  manifesto deixaria de ser portável para nginx ou kind.

## Armadilhas

- O `argocd-server` precisa de `configs.params."server.insecure": true`. Sem
  isso, com o Traefik terminando TLS, o resultado é `ERR_TOO_MANY_REDIRECTS`.
- "TRAEFIK DEFAULT CERT" no navegador significa que o cert-manager ainda não
  emitiu — é espera, não erro.
