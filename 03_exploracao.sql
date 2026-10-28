-- =====================================================================
-- StreamFlix | 03_exploracao.sql
-- Exploração inicial dos dados (PostgreSQL)
--
-- Como usar no pgAdmin: selecione com o mouse APENAS uma consulta
-- (do SELECT até o ponto e vírgula) e clique em play (ou F5).
-- Quando há texto selecionado, o pgAdmin roda só aquele trecho.
--
-- Data de corte dos dados: 2026-06-30
-- "Assinatura ativa" = data_fim IS NULL
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Qual é o período coberto pelos dados?
-- Técnica: subconsultas escalares (cada uma devolve um único valor)
-- ---------------------------------------------------------------------
SELECT
    (SELECT MIN(data_cadastro)    FROM usuarios)      AS primeiro_cadastro,
    (SELECT MAX(data_cadastro)    FROM usuarios)      AS ultimo_cadastro,
    (SELECT MIN(data_hora)::DATE  FROM visualizacoes) AS primeira_visualizacao,
    (SELECT MAX(data_hora)::DATE  FROM visualizacoes) AS ultima_visualizacao;


-- ---------------------------------------------------------------------
-- 2) Quantos usuários novos entram por mês?
-- Técnica: DATE_TRUNC + GROUP BY
-- ---------------------------------------------------------------------
SELECT
    DATE_TRUNC('month', data_cadastro)::DATE AS mes,
    COUNT(*)                                 AS novos_usuarios
FROM usuarios
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 3) De quais estados vêm os usuários?
-- Técnica: percentual do total com window function (SUM OVER)
-- ---------------------------------------------------------------------
SELECT
    estado,
    COUNT(*) AS usuarios,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM usuarios
GROUP BY estado
ORDER BY usuarios DESC;


-- ---------------------------------------------------------------------
-- 4) Como estão as assinaturas de cada plano (ativas x canceladas)?
-- Técnica: JOIN + COUNT com FILTER
-- ---------------------------------------------------------------------
SELECT
    p.nome AS plano,
    p.preco_mensal,
    COUNT(*)                                       AS total_assinaturas,
    COUNT(*) FILTER (WHERE a.data_fim IS NULL)     AS ativas,
    COUNT(*) FILTER (WHERE a.data_fim IS NOT NULL) AS canceladas
FROM assinaturas AS a
JOIN planos AS p USING (plano_id)
GROUP BY p.nome, p.preco_mensal
ORDER BY p.preco_mensal;


-- ---------------------------------------------------------------------
-- 5) Qual é a receita mensal recorrente (MRR) na data de corte?
-- Considera só assinaturas ativas. A linha TOTAL vem do ROLLUP.
-- Técnica: ROLLUP + COALESCE
-- ---------------------------------------------------------------------
SELECT
    COALESCE(p.nome, 'TOTAL') AS plano,
    COUNT(*)                  AS assinantes_ativos,
    SUM(p.preco_mensal)       AS mrr
FROM assinaturas AS a
JOIN planos AS p USING (plano_id)
WHERE a.data_fim IS NULL
GROUP BY ROLLUP (p.nome)
ORDER BY mrr DESC;


-- ---------------------------------------------------------------------
-- 6) Qual canal de origem converte mais cadastros em assinantes?
-- Técnica: LEFT JOIN (mantém quem nunca assinou) + taxa de conversão
-- ---------------------------------------------------------------------
SELECT
    u.canal_origem,
    COUNT(*)               AS usuarios,
    COUNT(a.assinatura_id) AS assinantes,
    ROUND(100.0 * COUNT(a.assinatura_id) / COUNT(*), 1) AS taxa_conversao_pct
FROM usuarios AS u
LEFT JOIN assinaturas AS a USING (usuario_id)
GROUP BY u.canal_origem
ORDER BY taxa_conversao_pct DESC;


-- ---------------------------------------------------------------------
-- 7) Quais são os 10 conteúdos mais assistidos?
-- Técnica: JOIN + agregação + LIMIT
-- ---------------------------------------------------------------------
SELECT
    c.titulo,
    c.genero,
    COUNT(*)                                 AS visualizacoes,
    ROUND(SUM(v.minutos_assistidos) / 60.0, 1) AS horas_assistidas
FROM visualizacoes AS v
JOIN conteudos AS c USING (conteudo_id)
GROUP BY c.conteudo_id, c.titulo, c.genero
ORDER BY visualizacoes DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- 8) Quais gêneros geram mais horas assistidas?
-- Técnica: agregação por categoria + média
-- ---------------------------------------------------------------------
SELECT
    c.genero,
    COUNT(*)                                    AS visualizacoes,
    ROUND(SUM(v.minutos_assistidos) / 60.0, 1)  AS horas_assistidas,
    ROUND(AVG(v.minutos_assistidos), 1)         AS media_minutos_por_view
FROM visualizacoes AS v
JOIN conteudos AS c USING (conteudo_id)
GROUP BY c.genero
ORDER BY horas_assistidas DESC;


-- ---------------------------------------------------------------------
-- 9) Em quais horários as pessoas mais assistem?
-- Técnica: EXTRACT para pegar a hora de um timestamp
-- ---------------------------------------------------------------------
SELECT
    EXTRACT(HOUR FROM data_hora)::INT AS hora,
    COUNT(*)                          AS visualizacoes
FROM visualizacoes
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 10) Quanto tempo duram as assinaturas que foram canceladas?
-- Atenção: considera só quem já cancelou, então subestima a duração real
-- (quem ainda está ativo fica de fora). A análise de coortes, mais
-- adiante, resolve esse viés.
-- Técnica: diferença entre datas + AVG
-- ---------------------------------------------------------------------
SELECT
    p.nome AS plano,
    COUNT(*) AS canceladas,
    ROUND(AVG(a.data_fim - a.data_inicio) / 30.0, 1) AS duracao_media_meses
FROM assinaturas AS a
JOIN planos AS p USING (plano_id)
WHERE a.data_fim IS NOT NULL
GROUP BY p.nome
ORDER BY duracao_media_meses DESC;
