-- =====================================================================
-- StreamFlix | 07_funil_conversao.sql
-- Funil de conversão: cadastro -> ativação -> assinatura (PostgreSQL)
--
-- Como usar no pgAdmin: selecione com o mouse APENAS uma consulta
-- (do WITH ou SELECT até o ponto e vírgula) e clique em play (ou F5).
-- Cada consulta é independente e traz a sua própria CTE.
--
-- Definições usadas neste arquivo:
--   - Ativação = o usuário assistiu pelo menos 1 conteúdo em até 14 dias
--     após o cadastro (dia 0 a dia 14)
--   - Conversão = o usuário tem alguma assinatura (cada usuário tem no
--     máximo uma assinatura nestes dados)
--   - Data de corte dos dados: 2026-06-30
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) Funil geral: quantos usuários chegam a cada etapa?
-- A etapa 3 conta só quem assinou E tinha assistido nos primeiros 14 dias,
-- então o funil é sequencial (cada etapa é subconjunto da anterior).
-- Técnica: EXISTS + UNION ALL + FIRST_VALUE e LAG
-- ---------------------------------------------------------------------
WITH flags AS (
    SELECT
        u.usuario_id,
        EXISTS (
            SELECT 1 FROM visualizacoes AS v
            WHERE v.usuario_id = u.usuario_id
              AND v.data_hora::DATE BETWEEN u.data_cadastro AND u.data_cadastro + 14
        ) AS ativou,
        EXISTS (
            SELECT 1 FROM assinaturas AS a
            WHERE a.usuario_id = u.usuario_id
        ) AS assinou
    FROM usuarios AS u
),
etapas AS (
    SELECT 1 AS ordem, '1. Cadastro' AS etapa, COUNT(*) AS usuarios
    FROM flags
    UNION ALL
    SELECT 2, '2. Assistiu algo em até 14 dias', COUNT(*) FILTER (WHERE ativou)
    FROM flags
    UNION ALL
    SELECT 3, '3. Assinou (entre os que assistiram)', COUNT(*) FILTER (WHERE ativou AND assinou)
    FROM flags
)
SELECT
    etapa,
    usuarios,
    ROUND(100.0 * usuarios / FIRST_VALUE(usuarios) OVER (ORDER BY ordem), 1)
        AS pct_do_total,
    ROUND(100.0 * usuarios / LAG(usuarios) OVER (ORDER BY ordem), 1)
        AS pct_da_etapa_anterior
FROM etapas
ORDER BY ordem;


-- ---------------------------------------------------------------------
-- 2) Quem assiste logo no início converte mais?
-- Compara a taxa de conversão de quem assistiu algo em até 14 dias com a
-- de quem não assistiu nada nesse período.
-- Atenção: nestes dados sintéticos, quem assina assiste mais desde o
-- cadastro, então essa diferença é em parte consequência de como os dados
-- foram gerados. Em dados reais seria uma correlação a investigar, que
-- não prova que assistir causa a assinatura.
-- Técnica: segmentação com CASE + taxa por grupo
-- ---------------------------------------------------------------------
WITH flags AS (
    SELECT
        u.usuario_id,
        EXISTS (
            SELECT 1 FROM visualizacoes AS v
            WHERE v.usuario_id = u.usuario_id
              AND v.data_hora::DATE BETWEEN u.data_cadastro AND u.data_cadastro + 14
        ) AS ativou,
        EXISTS (
            SELECT 1 FROM assinaturas AS a
            WHERE a.usuario_id = u.usuario_id
        ) AS assinou
    FROM usuarios AS u
)
SELECT
    CASE WHEN ativou THEN 'Assistiu em até 14 dias'
         ELSE 'Não assistiu em até 14 dias' END AS grupo,
    COUNT(*)                                    AS usuarios,
    COUNT(*) FILTER (WHERE assinou)             AS assinantes,
    ROUND(100.0 * COUNT(*) FILTER (WHERE assinou) / COUNT(*), 1)
                                                AS taxa_conversao_pct
FROM flags
GROUP BY ativou
ORDER BY ativou DESC;


-- ---------------------------------------------------------------------
-- 3) O funil é diferente em cada canal de origem?
-- pct_assinou_entre_ativados considera só quem assistiu em até 14 dias.
-- Técnica: múltiplas taxas na mesma consulta com FILTER
-- ---------------------------------------------------------------------
WITH flags AS (
    SELECT
        u.usuario_id,
        u.canal_origem,
        EXISTS (
            SELECT 1 FROM visualizacoes AS v
            WHERE v.usuario_id = u.usuario_id
              AND v.data_hora::DATE BETWEEN u.data_cadastro AND u.data_cadastro + 14
        ) AS ativou,
        EXISTS (
            SELECT 1 FROM assinaturas AS a
            WHERE a.usuario_id = u.usuario_id
        ) AS assinou
    FROM usuarios AS u
)
SELECT
    canal_origem,
    COUNT(*) AS cadastros,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ativou) / COUNT(*), 1)  AS pct_ativou,
    ROUND(100.0 * COUNT(*) FILTER (WHERE assinou) / COUNT(*), 1) AS pct_assinou,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE ativou AND assinou)
        / NULLIF(COUNT(*) FILTER (WHERE ativou), 0),
        1
    ) AS pct_assinou_entre_ativados
FROM flags
GROUP BY canal_origem
ORDER BY pct_assinou DESC;


-- ---------------------------------------------------------------------
-- 4) Em quantos dias os usuários assinam depois de se cadastrar?
-- Mostra a distribuição e o percentual acumulado.
-- Nestes dados sintéticos o prazo é sorteado de 0 a 14 dias, então a
-- distribuição sai quase uniforme. O interesse aqui é a técnica.
-- Técnica: window function acumulada (SUM OVER com ORDER BY)
-- ---------------------------------------------------------------------
WITH tempo AS (
    SELECT (a.data_inicio - u.data_cadastro) AS dias
    FROM assinaturas AS a
    JOIN usuarios AS u USING (usuario_id)
)
SELECT
    dias AS dias_ate_assinar,
    COUNT(*) AS assinaturas,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
    ROUND(100.0 * SUM(COUNT(*)) OVER (ORDER BY dias) / SUM(COUNT(*)) OVER (), 1)
        AS pct_acumulado
FROM tempo
GROUP BY dias
ORDER BY dias;


-- ---------------------------------------------------------------------
-- 5) A conversão está melhorando ou piorando ao longo do tempo?
-- Taxa de conversão por mês de cadastro.
-- Técnica: DATE_TRUNC + taxa por período
-- ---------------------------------------------------------------------
WITH flags AS (
    SELECT
        u.usuario_id,
        DATE_TRUNC('month', u.data_cadastro)::DATE AS mes_cadastro,
        EXISTS (
            SELECT 1 FROM assinaturas AS a
            WHERE a.usuario_id = u.usuario_id
        ) AS assinou
    FROM usuarios AS u
)
SELECT
    mes_cadastro,
    COUNT(*)                        AS cadastros,
    COUNT(*) FILTER (WHERE assinou) AS assinaram,
    ROUND(100.0 * COUNT(*) FILTER (WHERE assinou) / COUNT(*), 1)
                                    AS taxa_conversao_pct
FROM flags
GROUP BY mes_cadastro
ORDER BY mes_cadastro;
