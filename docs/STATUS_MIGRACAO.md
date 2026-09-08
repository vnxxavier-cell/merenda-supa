# Status da Migração — Supabase Auth e Fonte Oficial de Dados

Última atualização: 2026-09-08. Nenhuma alteração foi aplicada no banco até
que exista backup externo verificado e acesso administrativo seguro.

## 1. O que foi alterado no banco

Nada foi aplicado ainda. Todo o trabalho de banco está versionado em
`supabase/migrations/` e será aplicado pelos scripts do runbook.

## 2. O que foi alterado no código

- `index.html`: botão Salvar explícito no gerenciamento de perfis; painel
  "Aprovações Google" no admin; scripts V2 inertes carregados.
- `app_v2.js`: cliente server-first com Auth, salvamento por revisão, cache
  confirmado, sessão invalidada e eventos de status.
- `app_v2_bridge.js`: adaptador para captura e hidratação do cache legado.
- `supabase/functions/`: 4 Edge Functions e helpers compartilhados.
- `scripts/`: backup, verificação, aplicação de migrations e deploy de funções.
- `tests/`: checagens estáticas de contratos e de SQL.

## 3. Quais migrations foram criadas

| Migration | Conteúdo |
|---|---|
| `20260903000100_legacy_snapshots.sql` | Snapshots privados das tabelas legadas |
| `20260903000200_identity_and_ownership.sql` | `profiles`, mapa `legacy_user_id → auth.users.id`, colunas `owner_id`, solicitações Google pendentes |
| `20260903000300_domain_foundation.sql` | Tabelas canônicas: escolas, anos, períodos, ingredientes, fornecedores N:N, ofertas, contratos, ordens, fichas técnicas |
| `20260903000400_server_first_foundation.sql` | Sessão única, revisões, RPCs server-first, materialização de ownership, funções de login/Google |
| `20260903000500_admin_import_and_integrity.sql` | Administração protegida, aprovações Google, atribuição de fichas, integridade de tenant |
| `20260903000600_legacy_domain_import.sql` | Importação idempotente do domínio legado |
| `20260903990000_auth_rls_cutover.sql` | Corte final de RLS, com guardas que abortam se algo não estiver pronto |

## 4. Como os usuários existentes foram preservados

- `public.usuarios` não é apagado nem recriado.
- Um snapshot privado `app_private.usuarios_snapshot_20260903` é criado antes
  de qualquer mudança.
- Cada usuário antigo ganha um UUID do Supabase Auth e o mapeamento 1:1 em
  `app_private.legacy_user_id_map`; o ID antigo fica preservado.
- A migração de senha ocorre no primeiro login, validando o hash antigo
  somente no servidor (Edge Function), sem SHA-256 no navegador.
- `usr_admin`, `usr_admin_rede` e demais contas permanecem; `legacy_user_id`
  mantém a rastreabilidade.

## 5. Como os dados existentes foram preservados

- Snapshots privados de `usuarios`, `escola_dados` e `fichas_custom`.
- Documento canônico `school_state_documents` copia o estado legado sem
  removê-lo; a captura do cache do navegador só preenche chaves ausentes.
- O domínio é copiado para as tabelas novas com `ON CONFLICT DO NOTHING` ou
  preenchimento de nulos; nunca substitui valores canônicos já editados.
- Nenhuma migration desta fase faz DROP ou TRUNCATE de tabelas/colunas legadas.
- O corte final aborta se houver usuário sem mapeamento, estado sem dono,
  documento faltante, ficha não atribuída ou captura pendente.

## 6. Como ficou a autenticação

- Login tradicional migrado para Supabase Auth, mantendo usuário e senha.
- O hash legado é comparado apenas dentro da Edge Function `legacy-login`.
- Google: nova identidade fica pendente e sem acesso; o administrador aprova ou
  recusa no painel admin. A identidade aprovada usa o mesmo `auth.users.id`.

## 7. Como ficou a sessão única

- `app_private.user_sessions` guarda somente a sessão atual por usuário.
- Um novo login substitui a linha anterior; a sessão antiga deixa de ser a
  válida no banco e o frontend antigo detecta e encerra.
- `session-status` e a validação periódica do cliente reforçam a regra.
- Sem tabela de histórico de sessões.

## 8. Como ficou o RLS

- Tabelas novas já nascem com RLS habilitado e sem grants para `anon`.
- Políticas de leitura são baseadas em sessão ativa e membership da escola.
- O corte final habilita RLS nas tabelas legadas, remove policies legadas e
  revoga grants de navegador.
- Admin é validado no servidor (`app_private.user_authorizations` + sessão),
  nunca por variável JavaScript.

## 9. Como ficou a sincronização

- Supabase é a fonte oficial; salvamento passa por RPC com revisão esperada.
- Conflito de revisão devolve o estado atual do servidor e não sobrescreve.
- localStorage vira cache confirmado pós-servidor; não há mais `forceFullSync`.
- Erro de conexão não é tratado como salvamento concluído.
- Captura do cache legado é feita uma única vez, de forma controlada.

## 10. Quais testes foram realizados

- `tests/contract-check.ps1`: 14 arquivos e 24 contratos SQL ↔ Edge ↔ cliente.
- `tests/sql-static-check.ps1`: ordem, envelopes, tags, ausência de operações
  destrutivas e de auditoria/histórico, guardas do corte.
- Balanceamento de chaves/colchetes do `index.html` e dos scripts JS.
- Sintaxe PowerShell dos scripts de operação.
- Nenhum teste contra banco real foi executado por falta de acesso.

## 11. Pontos pendentes

1. Aplicar migrations no Supabase (aguarda CLI/token, backup `pg_dump` e acesso
   administrativo seguro).
2. Implantar as Edge Functions e configurar os secrets (mesmo bloqueio).
3. Validar em homologação antes de produção.
4. Aprovar as solicitações Google e migrar os usuários reais no primeiro login.
5. Aplicar o corte final de RLS somente após a prontidão passar.
6. Decidir o envio (push) dos 7 commits locais ao GitHub/Vercel.
7. Remover, em etapa posterior, o login SHA-256 antigo do frontend e o proxy de
   localStorage do legado — somente após o fluxo novo validado.
