-- =====================================================================
-- StreamFlix | 04_receita_assinaturas.sql
-- Receita e assinaturas ao longo do tempo (PostgreSQL)
--
-- Como usar no pgAdmin: selecione com o mouse APENAS uma consulta
-- (do WITH ou SELECT até o ponto e vírgula) e clique em play (ou F5).
--
-- Definições usadas neste arquivo:
--   - Data de corte dos dados: 2026-06-30
--   - Assinatura ATIVA em um mês = já tinha começado até o último dia do
--     mês e ainda não tinha terminado nesse dia (data_fim nula ou posterior)
--   - MRR = soma do preço mensal das assinaturas ativas (preço cheio)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Como o MRR evoluiu mês a mês?
-- Conferência: o último mês (2026-06) deve dar os mesmos assinantes e o
-- mesmo MRR da linha TOTAL da consulta 5 do arquivo 03.
-- Técnicas: generate_series, CTE, LEFT JOIN por intervalo, LAG
-- ---------------------------------------------------------------------
WITH meses AS (
    SELECT
        g::DATE AS mes_inicio,
        (g + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS ultimo_dia
    FROM generate_series(TIMESTAMP '2024-01-01',
                         TIMESTAMP '2026-06-01',
                         INTERVAL '1 month') AS g
),
mrr_mensal AS (
    SELECT
        m.mes_inicio                      AS mes,
        COUNT(a.assinatura_id)            AS assinantes_ativos,
        COALESCE(SUM(p.preco_mensal), 0)  AS mrr
    FROM meses AS m
    LEFT JOIN assinaturas AS a
           ON a.data_inicio <= m.ultimo_dia
          AND (a.data_fim IS NULL OR a.data_fim > m.ultimo_dia)
    LEFT JOIN planos AS p ON p.plano_id = a.plano_id
    GROUP BY m.mes_inicio
)
SELECT
    mes,
    assinantes_ativos,
    mrr,
    ROUND(
        100.0 * (mrr - LAG(mrr) OVER (ORDER BY mes))
        / NULLIF(LAG(mrr) OVER (ORDER BY mes), 0),
        1
    ) AS crescimento_mom_pct
FROM mrr_mensal
ORDER BY mes;


-- ---------------------------------------------------------------------
-- 2) Quantas assinaturas entram e saem por mês? (saldo líquido)
-- Técnica: duas CTEs + FULL OUTER JOIN
-- ---------------------------------------------------------------------
WITH novas AS (
    SELECT DATE_TRUNC('month', data_inicio)::DATE AS mes, COUNT(*) AS novas
    FROM assinaturas
    GROUP BY 1
),
cancelamentos AS (
    SELECT DATE_TRUNC('month', data_fim)::DATE AS mes, COUNT(*) AS cancelamentos
    FROM assinaturas
    WHERE data_fim IS NOT NULL
    GROUP BY 1
)
SELECT
    COALESCE(n.mes, c.mes)                          AS mes,
    COALESCE(n.novas, 0)                            AS novas,
    COALESCE(c.cancelamentos, 0)                    AS cancelamentos,
    COALESCE(n.novas, 0) - COALESCE(c.cancelamentos, 0) AS saldo_liquido
FROM novas AS n
FULL OUTER JOIN cancelamentos AS c ON n.mes = c.mes
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 3) Quanto cada plano contribui para o MRR em cada mês?
-- Técnica: "pivot" com SUM(...) FILTER
-- ---------------------------------------------------------------------
WITH meses AS (
    SELECT
        g::DATE AS mes_inicio,
        (g + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS ultimo_dia
    FROM generate_series(TIMESTAMP '2024-01-01',
                         TIMESTAMP '2026-06-01',
                         INTERVAL '1 month') AS g
)
SELECT
    m.mes_inicio AS mes,
    COALESCE(SUM(p.preco_mensal) FILTER (WHERE p.nome = 'Básico'),  0) AS mrr_basico,
    COALESCE(SUM(p.preco_mensal) FILTER (WHERE p.nome = 'Padrão'),  0) AS mrr_padrao,
    COALESCE(SUM(p.preco_mensal) FILTER (WHERE p.nome = 'Premium'), 0) AS mrr_premium,
    COALESCE(SUM(p.preco_mensal), 0)                                  AS mrr_total
FROM meses AS m
LEFT JOIN assinaturas AS a
       ON a.data_inicio <= m.ultimo_dia
      AND (a.data_fim IS NULL OR a.data_fim > m.ultimo_dia)
LEFT JOIN planos AS p ON p.plano_id = a.plano_id
GROUP BY m.mes_inicio
ORDER BY m.mes_inicio;


-- ---------------------------------------------------------------------
-- 4) Quem veio de anúncio, além de converter menos, também cancela mais?
-- Atenção: % de canceladas acumulado até a data de corte. Como todos os
-- canais têm distribuição parecida de datas de entrada, a comparação
-- entre canais é justa, mas o percentual absoluto depende da idade da base.
-- Técnica: JOIN + FILTER + média condicional
-- ---------------------------------------------------------------------
SELECT
    u.canal_origem,
    COUNT(*)                                       AS assinaturas,
    COUNT(*) FILTER (WHERE a.data_fim IS NOT NULL) AS canceladas,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.data_fim IS NOT NULL) / COUNT(*), 1)
                                                   AS pct_canceladas,
    ROUND(AVG(a.data_fim - a.data_inicio) FILTER (WHERE a.data_fim IS NOT NULL) / 30.0, 1)
                                                   AS duracao_media_meses_canceladas
FROM assinaturas AS a
JOIN usuarios AS u USING (usuario_id)
GROUP BY u.canal_origem
ORDER BY pct_canceladas DESC;


-- ---------------------------------------------------------------------
-- 5) Cancelamento por canal x plano (qual combinação é mais arriscada?)
-- Técnica: GROUP BY em duas dimensões
-- ---------------------------------------------------------------------
SELECT
    u.canal_origem,
    p.nome AS plano,
    COUNT(*) AS assinaturas,
    ROUND(100.0 * COUNT(*) FILTER (WHERE a.data_fim IS NOT NULL) / COUNT(*), 1)
         AS pct_canceladas
FROM assinaturas AS a
JOIN usuarios AS u USING (usuario_id)
JOIN planos   AS p USING (plano_id)
GROUP BY u.canal_origem, p.nome
ORDER BY pct_canceladas DESC;


-- ---------------------------------------------------------------------
-- 6) Quanto cada canal rende por usuário cadastrado? (receita acumulada)
-- Receita aproximada de cada assinatura = (dias de assinatura / 30) x preço.
-- Quem nunca assinou entra com receita zero (por isso o LEFT JOIN),
-- então o resultado mostra o retorno de cada cadastro, e não só dos
-- assinantes. Aproximação simples: ignora ciclos de cobrança exatos.
-- Técnica: CTE + LEFT JOIN + COALESCE
-- ---------------------------------------------------------------------
WITH receita_por_assinatura AS (
    SELECT
        a.usuario_id,
        (LEAST(COALESCE(a.data_fim, DATE '2026-06-30'), DATE '2026-06-30')
            - a.data_inicio) / 30.0 * p.preco_mensal AS receita
    FROM assinaturas AS a
    JOIN planos AS p USING (plano_id)
)
SELECT
    u.canal_origem,
    COUNT(*)                                          AS usuarios_cadastrados,
    ROUND(SUM(COALESCE(r.receita, 0)), 0)             AS receita_total,
    ROUND(SUM(COALESCE(r.receita, 0)) / COUNT(*), 2)  AS receita_por_usuario_cadastrado
FROM usuarios AS u
LEFT JOIN receita_por_assinatura AS r USING (usuario_id)
GROUP BY u.canal_origem
ORDER BY receita_por_usuario_cadastrado DESC;
