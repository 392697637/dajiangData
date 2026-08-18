

--   gis_error_log                        创建PG相关GIS错误日志

-- =============================================================================
-- PG相关GIS错误日志
-- =============================================================================
DROP TABLE IF EXISTS public.gis_error_log;

CREATE TABLE IF NOT EXISTS public.gis_error_log (
    id bigserial PRIMARY KEY,
    code integer,
    msg text,
    sqlstring text,
    create_time timestamp without time zone DEFAULT now()
);
COMMENT ON TABLE public.gis_error_log IS 'PG相关GIS错误日志';
COMMENT ON COLUMN public.gis_error_log.id IS '日志主键ID';
COMMENT ON COLUMN public.gis_error_log.code IS '错误状态码：400=参数/业务错误，500=系统异常';
COMMENT ON COLUMN public.gis_error_log.msg IS '错误提示信息';
COMMENT ON COLUMN public.gis_error_log.sqlstring IS '触发错误时的SQL语句';
COMMENT ON COLUMN public.gis_error_log.create_time IS '日志创建时间';

CREATE INDEX IF NOT EXISTS idx_gis_error_log_create_time
ON public.gis_error_log(create_time DESC);
COMMENT ON INDEX public.idx_gis_error_log_create_time IS 'PG相关GIS错误日志创建时间倒序查询索引';
