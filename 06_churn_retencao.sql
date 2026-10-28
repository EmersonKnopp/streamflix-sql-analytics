-- =====================================================================
-- StreamFlix | 06_churn_retencao.sql
-- Churn, tempo de vida, LTV e retenção por coorte (PostgreSQL)
--
-- Como usar no pgAdmin: selecione com o mouse APENAS uma consulta
-- (do WITH até o ponto e vírgula) e clique em play (ou F5).
--
-- Definições usadas neste arquivo:
--   - Data de corte dos dados: 2026-06-30
--   - Churn mensal = cancelamentos do mês / assinantes ativos no início do mês
--   - Coorte = mês em que a assinatura começou
--   - Retenção em M<k> = % da coorte ainda ativa k meses após o início.
--     Só entram assinaturas que já tiveram tempo de completar k meses até
--     a data de corte (senão a retenção ficaria artificialmente alta).
--
-- Este arquivo corrige uma limitação da consulta 4 do arquivo 04, que
-- comparava % de canceladas acumulado. Aqui o churn é medido por tempo de
-- exposição (meses de assinatura), que trata assinaturas novas e antigas
-- de forma justa.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Qual é a taxa de churn de cada mês?
-- Começa em fev/2024, porque em jan/2024 ainda não havia base no início.
-- Atenção: nos primeiros meses a base é pequena, então o percentual oscila.
-- Técnica: generate_series + COUNT(*) FILTER sobre intervalos de datas
-- ---------------------------------------------------------------------
WITH meses AS (
    SELECT
        g::DATE AS mes_inicio,
        (g + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS ultimo_dia
    FROM generate_series(TIMESTAMP '2024-02-01',
                         TIMESTAMP '2026-06-01',
                         INTERVAL '1 month') AS g
)
SELECT
    m.mes_inicio AS mes,
    COUNT(*) FILTER (
        WHERE a.data_inicio < m.mes_inicio
          AND (a.data_fim IS NULL OR a.data_fim >= m.mes_inicio)
    ) AS ativos_inicio_mes,
    COUNT(*) FILTER (
        WHERE a.data_fim BETWEEN m.mes_inicio AND m.ultimo_dia
    ) AS cancelamentos,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE a.data_fim BETWEEN m.mes_inicio AND m.ultimo_dia)
        / NULLIF(COUNT(*) FILTER (
              WHERE a.data_inicio < m.mes_inicio
                AND (a.data_fim IS NULL OR a.data_fim >= m.mes_inicio)
          ), 0),
        1
    ) AS churn_pct
FROM meses AS m
JOIN assinaturas AS a ON a.data_inicio <= m.ultimo_dia
GROUP BY m.mes_inicio
ORDER BY m.mes_inicio;


-- ---------------------------------------------------------------------
-- 2) Qual canal tem o maior churn mensal e a menor vida média?
-- churn mensal = cancelamentos / meses de assinatura acumulados
-- vida média estimada = meses de assinatura / cancelamentos
-- (mês aproximado como 30 dias)
-- Técnica: CTE de exposição + agregação com FILTER
-- ---------------------------------------------------------------------
WITH exposicao AS (
    SELECT
        a.assinatura_id,
        u.canal_origem,
        (a.data_fim IS NOT NULL) AS cancelou,
        (LEAST(COALESCE(a.data_fim, DATE '2026-06-30'), DATE '2026-06-30')
            - a.data_inicio) / 30.0 AS meses
    FROM assinaturas AS a
    JOIN usuarios AS u USING (usuario_id)
)
SELECT
    canal_origem,
    COUNT(*)                         AS assinaturas,
    COUNT(*) FILTER (WHERE cancelou) AS canceladas,
    ROUND(SUM(meses), 0)             AS meses_de_assinatura,
    ROUND(100.0 * COUNT(*) FILTER (WHERE cancelou) / SUM(meses), 1)
                                     AS churn_mensal_pct,
    ROUND(SUM(meses) / COUNT(*) FILTER (WHERE cancelou), 1)
                                     AS vida_media_estimada_meses
FROM exposicao
GROUP BY canal_origem
ORDER BY churn_mensal_pct DESC;


-- ---------------------------------------------------------------------
-- 3) Churn e LTV estimado por canal e plano
-- LTV estimado = preço mensal x vida média estimada (em meses).
-- É um LTV simples, de receita: não desconta custos nem usa taxa de
-- desconto. Serve para comparar combinações de canal e plano.
-- Técnica: GROUP BY em duas dimensões + métricas derivadas
-- ---------------------------------------------------------------------
WITH exposicao AS (
    SELECT
        a.assinatura_id,
        u.canal_origem,
        p.nome AS plano,
        p.preco_mensal,
        (a.data_fim IS NOT NULL) AS cancelou,
        (LEAST(COALESCE(a.data_fim, DATE '2026-06-30'), DATE '2026-06-30')
            - a.data_inicio) / 30.0 AS meses
    FROM assinaturas AS a
    JOIN usuarios AS u USING (usuario_id)
    JOIN planos   AS p USING (plano_id)
)
SELECT
    canal_origem,
    plano,
    COUNT(*)                         AS assinaturas,
    ROUND(100.0 * COUNT(*) FILTER (WHERE cancelou) / SUM(meses), 1)
                                     AS churn_mensal_pct,
    ROUND(SUM(meses) / COUNT(*) FILTER (WHERE cancelou), 1)
                                     AS vida_media_estimada_meses,
    ROUND(preco_mensal * SUM(meses) / COUNT(*) FILTER (WHERE cancelou), 0)
                                     AS ltv_estimado
FROM exposicao
GROUP BY canal_origem, plano, preco_mensal
ORDER BY ltv_estimado DESC;


-- ---------------------------------------------------------------------
-- 4) Retenção por coorte: de cada mês de entrada, quantos continuam
--    ativos 1, 3, 6 e 12 meses depois?
-- Células vazias (NULL) = a coorte ainda não completou esse prazo.
-- Técnica: flags por prazo em CTE + agregação com FILTER por coorte
-- ---------------------------------------------------------------------
WITH base AS (
    SELECT
        DATE_TRUNC('month', a.data_inicio)::DATE AS coorte,
        (a.data_inicio + INTERVAL '1 month'  <= DATE '2026-06-30') AS obs_m1,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '1 month')  AS ret_m1,
        (a.data_inicio + INTERVAL '3 months' <= DATE '2026-06-30') AS obs_m3,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '3 months') AS ret_m3,
        (a.data_inicio + INTERVAL '6 months' <= DATE '2026-06-30') AS obs_m6,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '6 months') AS ret_m6,
        (a.data_inicio + INTERVAL '12 months' <= DATE '2026-06-30') AS obs_m12,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '12 months') AS ret_m12
    FROM assinaturas AS a
)
SELECT
    coorte,
    COUNT(*) AS assinaturas,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m1  AND ret_m1)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m1), 0), 1)  AS retencao_m1_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m3  AND ret_m3)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m3), 0), 1)  AS retencao_m3_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m6  AND ret_m6)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m6), 0), 1)  AS retencao_m6_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m12 AND ret_m12)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m12), 0), 1) AS retencao_m12_pct
FROM base
GROUP BY coorte
ORDER BY coorte;


-- ---------------------------------------------------------------------
-- 5) Retenção por canal de origem (todas as coortes juntas)
-- Mesma lógica da consulta 4, agrupando por canal em vez de por mês.
-- Técnica: JOIN + flags por prazo + FILTER
-- ---------------------------------------------------------------------
WITH base AS (
    SELECT
        u.canal_origem,
        (a.data_inicio + INTERVAL '1 month'  <= DATE '2026-06-30') AS obs_m1,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '1 month')  AS ret_m1,
        (a.data_inicio + INTERVAL '3 months' <= DATE '2026-06-30') AS obs_m3,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '3 months') AS ret_m3,
        (a.data_inicio + INTERVAL '6 months' <= DATE '2026-06-30') AS obs_m6,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '6 months') AS ret_m6,
        (a.data_inicio + INTERVAL '12 months' <= DATE '2026-06-30') AS obs_m12,
        (a.data_fim IS NULL OR a.data_fim > a.data_inicio + INTERVAL '12 months') AS ret_m12
    FROM assinaturas AS a
    JOIN usuarios AS u USING (usuario_id)
)
SELECT
    canal_origem,
    COUNT(*) AS assinaturas,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m1  AND ret_m1)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m1), 0), 1)  AS retencao_m1_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m3  AND ret_m3)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m3), 0), 1)  AS retencao_m3_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m6  AND ret_m6)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m6), 0), 1)  AS retencao_m6_pct,
    ROUND(100.0 * COUNT(*) FILTER (WHERE obs_m12 AND ret_m12)
          / NULLIF(COUNT(*) FILTER (WHERE obs_m12), 0), 1) AS retencao_m12_pct
FROM base
GROUP BY canal_origem
ORDER BY retencao_m6_pct DESC;
