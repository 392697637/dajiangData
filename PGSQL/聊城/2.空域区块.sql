-- =============================================================================
-- 2.空域区块.sql
-- 表名称：public.bo_airspace_block
-- 表说明：空域区块信息表
-- 依赖说明：PostGIS 空间扩展。
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS postgis;

DROP TABLE IF EXISTS public.bo_airspace_block;

CREATE TABLE public.bo_airspace_block (
    id varchar(255) NOT NULL,
    outid varchar(255) NOT NULL,
    airspace_code varchar(255),
    airspace_name varchar(255),
    airspace_type varchar(255),
    airspace_area varchar(255),
    airspace_state varchar(255),
    min_height double precision,
    max_height double precision,
    use_date varchar(32),
    time_plan varchar(4000),
    status varchar(255),
    use_enabled boolean DEFAULT true,
    fence_type varchar(20),
    remark varchar(1000),
    create_time timestamp(6) without time zone NOT NULL,
    create_user varchar(32),
    update_time timestamp(6) without time zone NOT NULL,
    update_user varchar(32),
    del_flag boolean NOT NULL DEFAULT false,
    geom geometry,
    CONSTRAINT pk_bo_airspace_block PRIMARY KEY (id)
);

COMMENT ON TABLE public.bo_airspace_block IS '空域区块信息表';

COMMENT ON COLUMN public.bo_airspace_block.id IS '主键';
COMMENT ON COLUMN public.bo_airspace_block.outid IS 'OutId';
COMMENT ON COLUMN public.bo_airspace_block.airspace_code IS '空域编号';
COMMENT ON COLUMN public.bo_airspace_block.airspace_name IS '空域名称';
COMMENT ON COLUMN public.bo_airspace_block.airspace_type IS '空域类型（B类、D类）';
COMMENT ON COLUMN public.bo_airspace_block.airspace_area IS '空域面积';
COMMENT ON COLUMN public.bo_airspace_block.airspace_state IS '空域状态（管制 监视）';
COMMENT ON COLUMN public.bo_airspace_block.min_height IS '最低高度';
COMMENT ON COLUMN public.bo_airspace_block.max_height IS '最高高度';
COMMENT ON COLUMN public.bo_airspace_block.use_date IS '使用日期';
COMMENT ON COLUMN public.bo_airspace_block.time_plan IS '时间计划';
COMMENT ON COLUMN public.bo_airspace_block.status IS '数据状态（可用、不可用）';
COMMENT ON COLUMN public.bo_airspace_block.use_enabled IS '当前时间是否可用';
COMMENT ON COLUMN public.bo_airspace_block.fence_type IS '围栏类型（试飞区、管控区、禁飞区）';
COMMENT ON COLUMN public.bo_airspace_block.remark IS '备注';
COMMENT ON COLUMN public.bo_airspace_block.create_time IS '创建时间';
COMMENT ON COLUMN public.bo_airspace_block.create_user IS '创建者';
COMMENT ON COLUMN public.bo_airspace_block.update_time IS '更新时间';
COMMENT ON COLUMN public.bo_airspace_block.update_user IS '更新者';
COMMENT ON COLUMN public.bo_airspace_block.del_flag IS '是否删除：t删除；f未删除';
COMMENT ON COLUMN public.bo_airspace_block.geom IS '空间数据';

CREATE INDEX idx_bo_airspace_block_airspace_code
    ON public.bo_airspace_block (airspace_code);

CREATE INDEX idx_bo_airspace_block_fence_type
    ON public.bo_airspace_block (fence_type);

CREATE INDEX idx_bo_airspace_block_geom
    ON public.bo_airspace_block
    USING gist (geom);
