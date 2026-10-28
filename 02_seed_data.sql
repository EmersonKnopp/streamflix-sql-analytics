-- =====================================================================
-- StreamFlix | 02_seed_data.sql
-- Geração de dados sintéticos usando APENAS SQL (PostgreSQL 12+)
--
-- Pré-requisito: rodar antes o 01_schema.sql
-- Janela dos dados: cadastros de 2024-01-01 a 2026-06-30
--                   (plataforma lançada em jan/2024, com ritmo de
--                   cadastros crescendo ao longo do tempo)
--                   dados observados até a data de corte 2026-06-30
-- Volume aproximado: 5.000 usuários, ~3.800 assinaturas,
--                    200 conteúdos, ~150 mil visualizações
--
-- Reprodutibilidade: setseed() faz o random() gerar sempre os mesmos dados.
-- =====================================================================

SELECT setseed(0.42);

-- ---------------------------------------------------------------------
-- 1) PLANOS
-- ---------------------------------------------------------------------
INSERT INTO planos (nome, preco_mensal) VALUES
    ('Básico',  19.90),
    ('Padrão',  29.90),
    ('Premium', 44.90);

-- ---------------------------------------------------------------------
-- 2) USUÁRIOS (5.000)
--    Canal de origem com pesos: orgânico 50%, anúncio 35%, indicação 15%
-- ---------------------------------------------------------------------
INSERT INTO usuarios (data_cadastro, estado, canal_origem)
WITH sorteio AS MATERIALIZED (
    SELECT
        random() AS r_data,
        random() AS r_estado,
        random() AS r_canal
    FROM generate_series(1, 5000)
)
SELECT
    -- power(r, 0.8) empurra os cadastros para datas mais recentes
    -- (crescimento gradual); 912 dias = de 2024-01-01 até 2026-06-30
    DATE '2024-01-01' + floor(power(r_data, 0.8) * 912)::INT,
    (ARRAY['SP','RJ','MG','RS','BA','PR','PE','SC'])[1 + floor(r_estado * 8)::INT],
    CASE
        WHEN r_canal < 0.50 THEN 'organico'
        WHEN r_canal < 0.85 THEN 'anuncio'
        ELSE 'indicacao'
    END
FROM sorteio;

-- ---------------------------------------------------------------------
-- 3) CONTEÚDOS (200)
--    Títulos combinando prefixo + nome + número para ficarem únicos
-- ---------------------------------------------------------------------
INSERT INTO conteudos (titulo, genero, duracao_min)
SELECT
    (ARRAY['A Noite de','O Segredo de','Crônicas de','Além de',
           'O Último','Sombras de','Rumo a','Memórias de'])[1 + floor(random() * 8)::INT]
    || ' ' ||
    (ARRAY['Atlântida','Orion','Aurora','Vertigem','Horizonte',
           'Eclipse','Cobalto','Névoa','Quasar','Lume'])[1 + floor(random() * 10)::INT]
    || ' #' || n,
    (ARRAY['Drama','Comédia','Ação','Terror','Ficção Científica',
           'Documentário','Romance','Animação'])[1 + floor(random() * 8)::INT],
    30 + floor(random() * 120)::INT
FROM generate_series(1, 200) AS n;

-- ---------------------------------------------------------------------
-- 4) ASSINATURAS
--    - Taxa de conversão (cadastro -> assinante) depende do canal:
--      indicação 90%, orgânico 80%, anúncio 65%
--    - Plano: Básico 40%, Padrão 40%, Premium 20%
--    - Início: 0 a 14 dias após o cadastro (período de teste),
--      nunca depois da data de corte
--    - Churn mensal (p_churn): base 8%, +4 pp se veio de anúncio,
--      -3 pp se veio de indicação, +2 pp no Básico, -2 pp no Premium
--    - Duração em meses ~ distribuição geométrica com probabilidade p_churn
--    - data_fim NULL = assinatura ativa na data de corte (2026-06-30)
-- ---------------------------------------------------------------------
INSERT INTO assinaturas (usuario_id, plano_id, data_inicio, data_fim)
WITH base AS MATERIALIZED (
    SELECT
        usuario_id, data_cadastro, canal_origem,
        random() AS r_conv,
        random() AS r_plano,
        random() AS r_dur,
        random() AS r_dias
    FROM usuarios
),
convertidos AS (
    SELECT
        b.*,
        CASE
            WHEN r_plano < 0.40 THEN 1
            WHEN r_plano < 0.80 THEN 2
            ELSE 3
        END AS plano_id,
        LEAST(data_cadastro + floor(r_dias * 15)::INT, DATE '2026-06-30') AS data_inicio
    FROM base AS b
    WHERE r_conv < CASE canal_origem
                       WHEN 'indicacao' THEN 0.90
                       WHEN 'organico'  THEN 0.80
                       ELSE 0.65
                   END
),
com_churn AS (
    SELECT
        c.*,
        0.08
        + CASE canal_origem WHEN 'anuncio' THEN 0.04 WHEN 'indicacao' THEN -0.03 ELSE 0 END
        + CASE plano_id     WHEN 1 THEN 0.02 WHEN 3 THEN -0.02 ELSE 0 END AS p_churn
    FROM convertidos AS c
),
com_fim AS (
    SELECT
        cc.*,
        (data_inicio + make_interval(
            months => 1 + floor(ln(1 - r_dur) / ln(1 - p_churn))::INT
        ))::DATE AS data_fim_calc
    FROM com_churn AS cc
)
SELECT
    usuario_id,
    plano_id,
    data_inicio,
    CASE WHEN data_fim_calc > DATE '2026-06-30' THEN NULL ELSE data_fim_calc END
FROM com_fim
ORDER BY data_inicio;

-- ---------------------------------------------------------------------
-- 5) VISUALIZAÇÕES
--    - Assinantes: visualizam do cadastro até o fim da assinatura
--      (ou até a data de corte). Intensidade por usuário: 2 a 12 views/mês,
--      com poucos usuários muito engajados (power law).
--    - Antes de cancelar, o engajamento cai: nos últimos 30 dias, 60% das
--      visualizações são descartadas (sinal para análises de churn).
--    - Não assinantes: 55% assistem 1 a 4 conteúdos nos 14 dias após o cadastro.
--    - Popularidade: conteúdos de id baixo são bem mais assistidos.
--    - Horário: 60% das visualizações entre 18h e 23h.
--    - Minutos assistidos: entre 10% e 100% da duração do conteúdo.
-- ---------------------------------------------------------------------
INSERT INTO visualizacoes (usuario_id, conteudo_id, data_hora, minutos_assistidos)
WITH assinantes AS (
    SELECT
        a.usuario_id,
        u.data_cadastro AS data_ini,
        LEAST(COALESCE(a.data_fim, DATE '2026-06-30'), DATE '2026-06-30') AS data_ate,
        a.data_fim,
        2 + 10 * power(random(), 2) AS views_mes
    FROM assinaturas AS a
    JOIN usuarios AS u USING (usuario_id)
),
populacao AS MATERIALIZED (
    SELECT
        usuario_id, data_ini, data_ate, data_fim,
        round(views_mes * (data_ate - data_ini + 1) / 30.0)::INT AS n_views
    FROM assinantes

    UNION ALL

    SELECT
        u.usuario_id,
        u.data_cadastro,
        LEAST(u.data_cadastro + 13, DATE '2026-06-30'),
        NULL::DATE,
        CASE WHEN random() < 0.55 THEN 1 + floor(random() * 4)::INT ELSE 0 END
    FROM usuarios AS u
    WHERE NOT EXISTS (
        SELECT 1 FROM assinaturas AS a WHERE a.usuario_id = u.usuario_id
    )
),
eventos AS MATERIALIZED (
    SELECT
        p.usuario_id,
        p.data_fim,
        p.data_ini + floor(random() * (p.data_ate - p.data_ini + 1))::INT AS dia,
        1 + floor(power(random(), 2) * 200)::INT AS conteudo_id,
        random() AS r_hora,
        random() AS r_min,
        random() AS r_assist,
        random() AS r_thin
    FROM populacao AS p
    CROSS JOIN LATERAL generate_series(1, p.n_views) AS g
)
SELECT
    e.usuario_id,
    e.conteudo_id,
    e.dia::TIMESTAMP + make_interval(
        hours => CASE
                     WHEN e.r_hora < 0.6 THEN 18 + floor((e.r_hora / 0.6) * 6)::INT
                     ELSE floor(((e.r_hora - 0.6) / 0.4) * 18)::INT
                 END,
        mins  => floor(e.r_min * 60)::INT
    ),
    GREATEST(1, round(c.duracao_min * (0.1 + 0.9 * sqrt(e.r_assist)))::INT)
FROM eventos AS e
JOIN conteudos AS c USING (conteudo_id)
WHERE NOT (e.data_fim IS NOT NULL
           AND e.dia > e.data_fim - 30
           AND e.r_thin < 0.6);

-- ---------------------------------------------------------------------
-- 6) ÍNDICES (criados depois da carga para a inserção ser mais rápida)
-- ---------------------------------------------------------------------
CREATE INDEX idx_assinaturas_usuario  ON assinaturas (usuario_id);
CREATE INDEX idx_visualizacoes_usuario ON visualizacoes (usuario_id, data_hora);
CREATE INDEX idx_visualizacoes_conteudo ON visualizacoes (conteudo_id);

ANALYZE;

-- ---------------------------------------------------------------------
-- 7) CONFERÊNCIA RÁPIDA (rode e compare com os volumes esperados)
-- ---------------------------------------------------------------------
SELECT 'usuarios'      AS tabela, COUNT(*) AS linhas FROM usuarios
UNION ALL SELECT 'planos',        COUNT(*) FROM planos
UNION ALL SELECT 'assinaturas',   COUNT(*) FROM assinaturas
UNION ALL SELECT 'conteudos',     COUNT(*) FROM conteudos
UNION ALL SELECT 'visualizacoes', COUNT(*) FROM visualizacoes;

-- Distribuição por canal (esperado: ~50% organico, ~35% anuncio, ~15% indicacao)
SELECT canal_origem, COUNT(*) AS usuarios,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM usuarios
GROUP BY canal_origem
ORDER BY usuarios DESC;

-- Assinaturas ativas x canceladas
SELECT
    COUNT(*) FILTER (WHERE data_fim IS NULL)     AS ativas,
    COUNT(*) FILTER (WHERE data_fim IS NOT NULL) AS canceladas
FROM assinaturas;
