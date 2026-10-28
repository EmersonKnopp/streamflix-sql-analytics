-- =====================================================================
-- StreamFlix | 01_schema.sql
-- Criação das tabelas (PostgreSQL)
-- =====================================================================

DROP TABLE IF EXISTS visualizacoes, assinaturas, conteudos, usuarios, planos CASCADE;

CREATE TABLE planos (
    plano_id     SERIAL PRIMARY KEY,
    nome         VARCHAR(30)  NOT NULL,
    preco_mensal NUMERIC(6,2) NOT NULL
);

CREATE TABLE usuarios (
    usuario_id    SERIAL PRIMARY KEY,
    data_cadastro DATE        NOT NULL,
    estado        CHAR(2)     NOT NULL,
    canal_origem  VARCHAR(20) NOT NULL   -- organico, anuncio, indicacao
);

CREATE TABLE assinaturas (
    assinatura_id SERIAL PRIMARY KEY,
    usuario_id    INT  NOT NULL REFERENCES usuarios(usuario_id),
    plano_id      INT  NOT NULL REFERENCES planos(plano_id),
    data_inicio   DATE NOT NULL,
    data_fim      DATE               -- NULL = assinatura ativa
);

CREATE TABLE conteudos (
    conteudo_id SERIAL PRIMARY KEY,
    titulo      VARCHAR(80) NOT NULL,
    genero      VARCHAR(20) NOT NULL,
    duracao_min INT         NOT NULL
);

CREATE TABLE visualizacoes (
    visualizacao_id    SERIAL PRIMARY KEY,
    usuario_id         INT       NOT NULL REFERENCES usuarios(usuario_id),
    conteudo_id        INT       NOT NULL REFERENCES conteudos(conteudo_id),
    data_hora          TIMESTAMP NOT NULL,
    minutos_assistidos INT       NOT NULL
);
