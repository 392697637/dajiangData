-- =============================================================================
-- 9.3清空表日志.sql
--   gis_cleanup_track_log_tables            清理轨迹表和日志表历史数据
--
-- 文件定位：
--   用于定期清理高频增长表，主要包括：
--     1. gis_flight_paths                    无人机3D规划飞行路径/轨迹记录表
--     2. gis_error_log                       PG GIS 函数错误日志表
--     3. bo_counter_device_warning_notice    反制设备实时点位预警通知表（存在时清理）
--
-- 推荐策略：
--   1. 默认保留最近 7 天数据，每周执行一次。
--   2. 第一次上线建议先 dry_run=true 预估删除数量，再 dry_run=false 正式清理。
--   3. 大表清理后执行 ANALYZE，让优化器更新统计信息。
--
-- 重要说明：
--   本脚本不是 TRUNCATE 全表清空，而是按时间清理历史数据。
--   如果确实要全表清空，请使用文件尾部“手动全表清空示例”，执行前必须确认业务影响。
-- =============================================================================

-- =============================================================================
-- 删除函数
-- =============================================================================
SELECT gis_drop_function('gis_cleanup_track_log_tables');

-- =============================================================================
-- 函数介绍：gis_cleanup_track_log_tables
-- 主要作用：按保留天数清理轨迹表和日志表历史数据。
-- 入参说明：
--   p_keep_days       保留最近多少天数据，默认 7；传 0 表示清理今天 00:00 以前的数据
--   p_dry_run         试运行开关，true=只统计不删除，false=正式删除
--   p_analyze_after   清理后是否执行 ANALYZE，默认 true
-- 返回说明：
--   每张表返回一行，包含表名、清理条件、预计/实际删除数量和执行消息。
-- =============================================================================
CREATE OR REPLACE FUNCTION public.gis_cleanup_track_log_tables(
    p_keep_days integer DEFAULT 7,
    p_dry_run boolean DEFAULT true,
    p_analyze_after boolean DEFAULT true
)
RETURNS TABLE (
    code integer,
    msg varchar,
    table_name varchar,
    cutoff_time timestamptz,
    deleted_count bigint,
    dry_run boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_keep_days integer := GREATEST(COALESCE(p_keep_days, 7), 0);
    v_cutoff timestamptz := now() - make_interval(days => GREATEST(COALESCE(p_keep_days, 7), 0));
    v_count bigint := 0;
    v_sql text;
    v_start_time timestamptz := clock_timestamp();
BEGIN
    -- 传 0 时按“今天 00:00 以前”清理，避免 now() 边界导致当天刚写入的数据被清掉。
    IF v_keep_days = 0 THEN
        v_cutoff := date_trunc('day', now());
    END IF;

    -- =====================================================================
    -- 1. 清理 gis_flight_paths：无人机3D规划飞行路径/轨迹记录表
    -- =====================================================================
    IF to_regclass('public.gis_flight_paths') IS NOT NULL THEN
        IF p_dry_run THEN
            SELECT COUNT(*) INTO v_count
            FROM public.gis_flight_paths
            WHERE create_time < v_cutoff;
        ELSE
            DELETE FROM public.gis_flight_paths
            WHERE create_time < v_cutoff;
            GET DIAGNOSTICS v_count = ROW_COUNT;

            IF p_analyze_after THEN
                ANALYZE public.gis_flight_paths;
            END IF;
        END IF;

        RETURN QUERY SELECT
            200,
            format('%s：gis_flight_paths 清理完成，执行时间 %s 秒',
                CASE WHEN p_dry_run THEN '试运行' ELSE '正式执行' END,
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            'gis_flight_paths'::varchar,
            v_cutoff,
            v_count,
            p_dry_run;
    ELSE
        RETURN QUERY SELECT
            400,
            '表不存在：gis_flight_paths'::varchar,
            'gis_flight_paths'::varchar,
            v_cutoff,
            0::bigint,
            p_dry_run;
    END IF;

    -- =====================================================================
    -- 2. 清理 gis_error_log：PG GIS 函数错误日志表
    -- =====================================================================
    IF to_regclass('public.gis_error_log') IS NOT NULL THEN
        IF p_dry_run THEN
            SELECT COUNT(*) INTO v_count
            FROM public.gis_error_log
            WHERE create_time < v_cutoff;
        ELSE
            DELETE FROM public.gis_error_log
            WHERE create_time < v_cutoff;
            GET DIAGNOSTICS v_count = ROW_COUNT;

            IF p_analyze_after THEN
                ANALYZE public.gis_error_log;
            END IF;
        END IF;

        RETURN QUERY SELECT
            200,
            format('%s：gis_error_log 清理完成，执行时间 %s 秒',
                CASE WHEN p_dry_run THEN '试运行' ELSE '正式执行' END,
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            'gis_error_log'::varchar,
            v_cutoff,
            v_count,
            p_dry_run;
    ELSE
        RETURN QUERY SELECT
            400,
            '表不存在：gis_error_log'::varchar,
            'gis_error_log'::varchar,
            v_cutoff,
            0::bigint,
            p_dry_run;
    END IF;

    -- =====================================================================
    -- 3. 清理 bo_counter_device_warning_notice：反制设备实时点位预警通知表
    --    该表由 7.反制设备.sql 创建；如果当前库不存在则跳过。
    -- =====================================================================
    IF to_regclass('public.bo_counter_device_warning_notice') IS NOT NULL THEN
        IF p_dry_run THEN
            SELECT COUNT(*) INTO v_count
            FROM public.bo_counter_device_warning_notice
            WHERE create_time < v_cutoff;
        ELSE
            DELETE FROM public.bo_counter_device_warning_notice
            WHERE create_time < v_cutoff;
            GET DIAGNOSTICS v_count = ROW_COUNT;

            IF p_analyze_after THEN
                ANALYZE public.bo_counter_device_warning_notice;
            END IF;
        END IF;

        RETURN QUERY SELECT
            200,
            format('%s：bo_counter_device_warning_notice 清理完成，执行时间 %s 秒',
                CASE WHEN p_dry_run THEN '试运行' ELSE '正式执行' END,
                ROUND(EXTRACT(epoch FROM clock_timestamp() - v_start_time)::numeric, 3))::varchar,
            'bo_counter_device_warning_notice'::varchar,
            v_cutoff,
            v_count,
            p_dry_run;
    ELSE
        RETURN QUERY SELECT
            200,
            '表不存在，已跳过：bo_counter_device_warning_notice'::varchar,
            'bo_counter_device_warning_notice'::varchar,
            v_cutoff,
            0::bigint,
            p_dry_run;
    END IF;

EXCEPTION WHEN OTHERS THEN
    RETURN QUERY SELECT
        500,
        format('清理异常：%s', SQLERRM)::varchar,
        ''::varchar,
        v_cutoff,
        0::bigint,
        p_dry_run;
END;
$$;
COMMENT ON FUNCTION public.gis_cleanup_track_log_tables(integer, boolean, boolean) IS '按保留天数清理轨迹表和日志表历史数据';


-- =============================================================================
-- 一周清理一次：推荐 pg_cron 方案
-- =============================================================================
-- 说明：
--   pg_cron 是 PostgreSQL 内部定时任务扩展，适合数据库服务器统一管理定时清理。
--   如果数据库未安装 pg_cron，请使用后面的 Linux crontab 或 Windows 任务计划方案。
--
-- 安装前提：
--   1. 数据库服务端已安装 pg_cron。
--   2. postgresql.conf 配置 shared_preload_libraries 包含 pg_cron。
--   3. 修改 shared_preload_libraries 后需要重启 PostgreSQL。
--
-- 启用扩展：
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
--
-- 每周日凌晨 03:00 清理一次，保留最近 7 天，正式执行：
-- SELECT cron.schedule(
--     'weekly_cleanup_track_log_tables',
--     '0 3 * * 0',
--     $$SELECT * FROM public.gis_cleanup_track_log_tables(7, false, true);$$
-- );
--
-- 查看任务：
-- SELECT jobid, schedule, command, active, jobname
-- FROM cron.job
-- ORDER BY jobid;
--
-- 取消任务：
-- SELECT cron.unschedule('weekly_cleanup_track_log_tables');


-- =============================================================================
-- 一周清理一次：Linux crontab 方案
-- =============================================================================
-- 每周日凌晨 03:00 执行，保留最近 7 天。
-- 注意替换主机、端口、数据库、用户名；密码建议放在 ~/.pgpass，不要写进命令。
--
-- 0 3 * * 0 psql -h 127.0.0.1 -p 5432 -U postgres -d your_database -c "SELECT * FROM public.gis_cleanup_track_log_tables(7, false, true);"


-- =============================================================================
-- 一周清理一次：Windows 任务计划方案
-- =============================================================================
-- 1. 新建文件：E:\CHAJIAN\dajiangData\PGSQL\cleanup_track_log_weekly.sql
--    内容如下：
--      SELECT * FROM public.gis_cleanup_track_log_tables(7, false, true);
--
-- 2. 任务计划程序配置：
--    触发器：每周，星期日，03:00
--    操作程序：
--      C:\Program Files\PostgreSQL\17\bin\psql.exe
--    参数示例：
--      -h 127.0.0.1 -p 5432 -U postgres -d your_database -f "E:\CHAJIAN\dajiangData\PGSQL\cleanup_track_log_weekly.sql"
--
-- 3. 密码处理：
--    建议配置 pgpass.conf，避免把数据库密码写在任务计划参数中。


-- =============================================================================
-- 手动调用示例
-- =============================================================================
-- 示例1：试运行，查看如果保留 7 天会删除多少数据，不真正删除。
-- SELECT * FROM public.gis_cleanup_track_log_tables(7, true, true);
--
-- 示例2：正式清理，保留最近 7 天。
-- SELECT * FROM public.gis_cleanup_track_log_tables(7, false, true);
--
-- 示例3：保留最近 30 天。
-- SELECT * FROM public.gis_cleanup_track_log_tables(30, false, true);
--
-- 示例4：清理今天 00:00 以前的数据。
-- SELECT * FROM public.gis_cleanup_track_log_tables(0, false, true);


-- =============================================================================
-- 手动全表清空示例：高风险，默认注释
-- =============================================================================
-- 说明：
--   TRUNCATE 会直接清空整张表，不能按时间保留。
--   生产环境建议优先使用 gis_cleanup_track_log_tables 按时间删除。
--
-- 清空轨迹表：
-- TRUNCATE TABLE public.gis_flight_paths RESTART IDENTITY;
--
-- 清空错误日志表：
-- TRUNCATE TABLE public.gis_error_log RESTART IDENTITY;
--
-- 清空反制设备预警通知表：
-- TRUNCATE TABLE public.bo_counter_device_warning_notice RESTART IDENTITY;
