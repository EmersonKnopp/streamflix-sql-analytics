-- =====================================================================
-- StreamFlix | 05_engajamento.sql
-- Engajamento dos usuários e sinais de risco de cancelamento (PostgreSQL)
--
-- Como usar no pgAdmin: selecione com o mouse APENAS uma consulta
-- (do WITH ou SELECT até o ponto e vírgula) e clique em play (ou F5).
--
-- Definições usadas neste arquivo:
--   - Data de corte dos dados: 2026-06-30
--   - Usuário ativo no mês = assistiu pelo menos 1 conteúdo no mês
--   - Horas assistidas = soma de minutos_assistidos / 60
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Visão geral do engajamento
-- Técnica: agregações simples e COUNT(DISTINCT ...)
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                   AS visualizacoes,
    COUNT(DISTINCT usuario_id)                 AS usuarios_que_assistiram,
    ROUND(SUM(minutos_assistidos) / 60.0, 0)   AS horas_totais,
    ROUND(AVG(minutos_assistidos), 1)          AS media_minutos_por_view
FROM visualizacoes;


-- ---------------------------------------------------------------------
-- 2) Quantos usuários ativos por mês e quanto cada um assiste?
-- Técnica: DATE_TRUNC + COUNT(DISTINCT) + razão entre agregados
-- ---------------------------------------------------------------------
SELECT
    DATE_TRUNC('month', data_hora)::DATE AS mes,
    COUNT(DISTINCT usuario_id)           AS usuarios_ativos,
    COUNT(*)                             AS visualizacoes,
    ROUND(SUM(minutos_assistidos) / 60.0, 0) AS horas_assistidas,
    ROUND(SUM(minutos_assistidos) / 60.0 / COUNT(DISTINCT usuario_id), 1)
                                         AS horas_por_usuario_ativo
FROM visualizacoes
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- 3) O catálogo é concentrado? Quanto das views vem dos títulos mais
--    populares? (os 200 títulos divididos em 5 grupos de 40)
-- Quintil 1 = os 20% de títulos mais assistidos.
-- LEFT JOIN mantém títulos que ninguém assistiu (com zero views).
-- Técnica: NTILE + soma sobre soma (window sobre agregado)
-- ---------------------------------------------------------------------
WITH views_por_conteudo AS (
    SELECT
        c.conteudo_id,
        COUNT(v.visualizacao_id) AS views
    FROM conteudos AS c
    LEFT JOIN visualizacoes AS v USING (conteudo_id)
    GROUP BY c.conteudo_id
),
ranqueado AS (
    SELECT
        conteudo_id,
        views,
        NTILE(5) OVER (ORDER BY views DESC) AS quintil
    FROM views_por_conteudo
)
SELECT
    quintil,
    COUNT(*)   AS conteudos,
    SUM(views) AS visualizacoes,
    ROUND(100.0 * SUM(views) / SUM(SUM(views)) OVER (), 1) AS pct_das_views
FROM ranqueado
GROUP BY quintil
ORDER BY quintil;


-- ---------------------------------------------------------------------
-- 4) Os usuários mais engajados concentram quanto do consumo?
-- Decil 1 = os 10% de usuários que mais assistiram.
-- Atenção: são horas acumuladas desde o cadastro, então quem está há mais
-- tempo na plataforma tende a aparecer nos decis de cima.
-- Técnica: NTILE(10) + participação percentual
-- ---------------------------------------------------------------------
WITH horas_por_usuario AS (
    SELECT
        usuario_id,
        SUM(minutos_assistidos) / 60.0 AS horas
    FROM visualizacoes
    GROUP BY usuario_id
),
decis AS (
    SELECT
        usuario_id,
        horas,
        NTILE(10) OVER (ORDER BY horas DESC) AS decil
    FROM horas_por_usuario
)
SELECT
    decil,
    COUNT(*)                                              AS usuarios,
    ROUND(SUM(horas), 0)                                  AS horas,
    ROUND(100.0 * SUM(horas) / SUM(SUM(horas)) OVER (), 1) AS pct_das_horas,
    ROUND(AVG(horas), 1)                                  AS media_horas_por_usuario
FROM decis
GROUP BY decil
ORDER BY decil;


-- ---------------------------------------------------------------------
-- 5) O engajamento cai antes do cancelamento?
-- Para cada assinatura com pelo menos 60 dias de vida, compara as views
-- dos últimos 30 dias com as dos 30 dias anteriores a eles.
--   - cancelada: janelas contadas a partir da data de cancelamento
--   - ativa: janelas contadas a partir da data de corte (2026-06-30)
-- Atenção: nestes dados sintéticos esse padrão foi plantado de propósito
-- no 02_seed_data.sql. Em dados reais, seria uma hipótese a validar.
-- Técnica: CTEs + LEFT JOIN + COUNT(*) FILTER por janela de tempo
-- ---------------------------------------------------------------------
WITH referencia AS (
    SELECT
        a.usuario_id,
        COALESCE(a.data_fim, DATE '2026-06-30') AS data_ref,
        CASE WHEN a.data_fim IS NULL THEN 'ativa' ELSE 'cancelada' END AS situacao
    FROM assinaturas AS a
    WHERE COALESCE(a.data_fim, DATE '2026-06-30') - a.data_inicio >= 60
),
janelas AS (
    SELECT
        r.situacao,
        r.usuario_id,
        COUNT(*) FILTER (
            WHERE v.data_hora::DATE >  r.data_ref - 30
              AND v.data_hora::DATE <= r.data_ref
        ) AS views_ultimos_30d,
        COUNT(*) FILTER (
            WHERE v.data_hora::DATE >  r.data_ref - 60
              AND v.data_hora::DATE <= r.data_ref - 30
        ) AS views_30d_anteriores
    FROM referencia AS r
    LEFT JOIN visualizacoes AS v ON v.usuario_id = r.usuario_id
    GROUP BY r.situacao, r.usuario_id
)
SELECT
    situacao,
    COUNT(*)                                   AS assinaturas,
    ROUND(AVG(views_30d_anteriores), 1)        AS media_views_30d_anteriores,
    ROUND(AVG(views_ultimos_30d), 1)           AS media_views_ultimos_30d,
    ROUND(
        100.0 * (AVG(views_ultimos_30d) - AVG(views_30d_anteriores))
        / NULLIF(AVG(views_30d_anteriores), 0),
        1
    )                                          AS variacao_pct
FROM janelas
GROUP BY situacao
ORDER BY situacao;


-- ---------------------------------------------------------------------
-- 6) Quanto da receita está em risco hoje?
-- Assinante ativo "em risco" = não assistiu nada nos últimos 30 dias
-- (ou nunca assistiu). Mostra a quantidade e o MRR dessas assinaturas.
-- Técnica: flag booleano em CTE + agregação com FILTER
-- ---------------------------------------------------------------------
WITH ultima_atividade AS (
    SELECT
        a.usuario_id,
        a.plano_id,
        (MAX(v.data_hora) IS NULL
         OR MAX(v.data_hora)::DATE < DATE '2026-06-30' - 30) AS em_risco
    FROM assinaturas AS a
    LEFT JOIN visualizacoes AS v ON v.usuario_id = a.usuario_id
    WHERE a.data_fim IS NULL
    GROUP BY a.usuario_id, a.plano_id
)
SELECT
    COUNT(*)                                         AS assinantes_ativos,
    COUNT(*) FILTER (WHERE u.em_risco)               AS em_risco,
    ROUND(100.0 * COUNT(*) FILTER (WHERE u.em_risco) / COUNT(*), 1)
                                                     AS pct_em_risco,
    SUM(p.preco_mensal)                              AS mrr_total,
    COALESCE(SUM(p.preco_mensal) FILTER (WHERE u.em_risco), 0)
                                                     AS mrr_em_risco
FROM ultima_atividade AS u
JOIN planos AS p USING (plano_id);
