-- ============================================================
-- 函数名称：gis_project_data
-- 功能说明：循环读取 bo_project 表中的项目 id 和 region_shape，
--          依次调用以下项目数据初始化函数：
--          1. gis_generate_3d_grid(id, region_shape_geojson, 50, 280, 100)
--          2. gis_electric_fence_project(id, region_shape_geojson)
--          3. gis_mark_electric_fence(id)
--
-- 返回字段：
--   code        integer  返回码：200成功，400参数错误，500空间冲突/执行异常
--   msg         text     结果描述
--   sql_name    text     对应函数名称
--   sql_time    text     执行时间（秒）
--   table_name  text     对应的表名
--   table_count text     对应表数据量
--   exec_start  timestamptz  执行开始时间
--   exec_end    timestamptz  执行结束时间
--   exec_time   numeric      执行耗时（秒，保留3位小数）
-- 使用示例：
--   SELECT * FROM gis_project_data();
--   SELECT * FROM gis_project_data('2c95908e9aed844e019aeda0440f0455');
--
-- 并行执行说明：
--   PostgreSQL 单个函数调用不会在函数内部自动开多线程。
--   如项目较多，可使用文件末尾的 gis_project_data_batch(worker_no, worker_count)，
--   在多个数据库连接中同时执行不同分片。
--   示例：开 4 个 SQL 窗口，分别执行：
--     SELECT * FROM gis_project_data_batch(0, 4);
--     SELECT * FROM gis_project_data_batch(1, 4);
--     SELECT * FROM gis_project_data_batch(2, 4);
--     SELECT * FROM gis_project_data_batch(3, 4);
-- 数据范围：
--   仅处理 bo_project.del_flag = false 且 region_shape 不为空的数据。
-- ============================================================

DROP FUNCTION IF EXISTS public.gis_project_data(text);

CREATE OR REPLACE FUNCTION public.gis_project_data(
    p_project_id text DEFAULT NULL
)
RETURNS TABLE (
    code integer,
    msg text,
    sql_name text,
    sql_time text,
    table_name text,
    table_count text
    ,exec_start timestamptz
    ,exec_end timestamptz
    ,exec_time numeric
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- 项目记录：来自 bo_project，region_shape 作为项目空间范围。
    v_project record;

    -- 下游函数统一使用 record 接收，兼容 count/table_name 等返回字段。
    v_result record;

    -- 项目范围 GeoJSON。PostGIS 函数入参要求文本格式 GeoJSON。
    v_geom_json text;

    -- 单个函数调用开始时间，用于统计执行耗时。
    v_start_time timestamptz;
    v_end_time timestamptz;
    v_exec_time numeric;

    -- 是否实际循环到项目，用于最后返回空数据提示。
    v_has_project boolean := false;
BEGIN
    -- 按项目循环执行；p_project_id 为空时处理全部未删除项目。
    FOR v_project IN
        SELECT bp.id, bp.region_shape
        FROM public.bo_project bp
        WHERE bp.region_shape IS NOT NULL
          AND bp.del_flag = false
          AND (p_project_id IS NULL OR p_project_id = '' OR bp.id = p_project_id)
        ORDER BY bp.id
    LOOP
        v_has_project := true;
        v_geom_json := ST_AsGeoJSON(v_project.region_shape)::text;

        -- 1. 生成项目三维网格表，默认参数：最低高度50、最高高度280、网格分辨率100。
        BEGIN
            v_start_time := clock_timestamp();

            SELECT *
            INTO v_result
            FROM public.gis_generate_3d_grid(
                v_project.id,
                v_geom_json,
                50,
                280,
                100
            );
            v_end_time := clock_timestamp();
            v_exec_time := ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3);

            RETURN QUERY SELECT
                COALESCE(v_result.code, 500)::integer,
                COALESCE(v_result.msg, '')::text,
                'gis_generate_3d_grid'::text,
                ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3)::text,
                COALESCE(v_result.table_name, '')::text,
                COALESCE(v_result.count, 0)::text,
                v_start_time,
                v_end_time,
                v_exec_time;
        EXCEPTION WHEN OTHERS THEN
            v_end_time := clock_timestamp();
            v_exec_time := ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3);
            RETURN QUERY SELECT
                500::integer,
                SQLERRM::text,
                'gis_generate_3d_grid'::text,
                ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3)::text,
                ''::text,
                '0'::text,
                v_start_time,
                v_end_time,
                v_exec_time;
        END;

        -- 2. 创建并导入项目专属电子围栏表。
        BEGIN
            v_start_time := clock_timestamp();

            SELECT *
            INTO v_result
            FROM public.gis_electric_fence_project(
                v_project.id,
                v_geom_json
            );
            v_end_time := clock_timestamp();
            v_exec_time := ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3);

            RETURN QUERY SELECT
                COALESCE(v_result.code, 500)::integer,
                COALESCE(v_result.msg, '')::text,
                'gis_electric_fence_project'::text,
                ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3)::text,
                COALESCE(v_result.table_name, '')::text,
                COALESCE(v_result.count, 0)::text,
                v_start_time,
                v_end_time,
                v_exec_time;
        EXCEPTION WHEN OTHERS THEN
            v_end_time := clock_timestamp();
            v_exec_time := ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3);
            RETURN QUERY SELECT
                500::integer,
                SQLERRM::text,
                'gis_electric_fence_project'::text,
                ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3)::text,
                ''::text,
                '0'::text,
                v_start_time,
                v_end_time,
                v_exec_time;
        END;

        -- 3. 根据项目电子围栏刷新三维网格点的围栏标记。
        BEGIN
            v_start_time := clock_timestamp();

            SELECT *
            INTO v_result
            FROM public.gis_mark_electric_fence(v_project.id);
            v_end_time := clock_timestamp();
            v_exec_time := ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3);

            RETURN QUERY SELECT
                COALESCE(v_result.code, 500)::integer,
                COALESCE(v_result.msg, '')::text,
                'gis_mark_electric_fence'::text,
                ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3)::text,
                COALESCE(v_result.table_name, '')::text,
                COALESCE(v_result.count, 0)::text,
                v_start_time,
                v_end_time,
                v_exec_time;
        EXCEPTION WHEN OTHERS THEN
            v_end_time := clock_timestamp();
            v_exec_time := ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3);
            RETURN QUERY SELECT
                500::integer,
                SQLERRM::text,
                'gis_mark_electric_fence'::text,
                ROUND(EXTRACT(EPOCH FROM v_end_time - v_start_time)::numeric, 3)::text,
                ''::text,
                '0'::text,
                v_start_time,
                v_end_time,
                v_exec_time;
        END;
    END LOOP;

    -- 指定项目不存在或没有 region_shape 时，给出明确提示。
    IF NOT v_has_project THEN
        RETURN QUERY SELECT
            400::integer,
            'bo_project 中没有找到 del_flag=false 且 region_shape 不为空的项目数据'::text,
            'gis_project_data'::text,
            '0'::text,
            ''::text,
            '0'::text,
            NULL::timestamptz,
            NULL::timestamptz,
            0::numeric;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.gis_project_data(text) IS
'循环读取 bo_project.id 和 region_shape，生成三维网格、项目电子围栏并刷新围栏标记';


-- ============================================================
-- 函数名称：gis_project_data_batch
-- 功能说明：按项目 id 哈希分片处理 bo_project，用于多连接并行执行。
--
-- 参数说明：
--   p_worker_no     当前分片编号，从 0 开始。
--   p_worker_count  总分片数量，也就是并行连接数量。
--
-- 使用示例：
--   -- 开 4 个 SQL 窗口并行执行以下 4 条：
--   SELECT * FROM gis_project_data_batch(0, 4);
--   SELECT * FROM gis_project_data_batch(1, 4);
--   SELECT * FROM gis_project_data_batch(2, 4);
--   SELECT * FROM gis_project_data_batch(3, 4);
--
-- 注意事项：
--   1. p_worker_no 必须满足：0 <= p_worker_no < p_worker_count。
--   2. 多连接并行会增加 CPU、IO、锁和临时表压力，建议先从 2 或 4 个并行开始。
--   3. 每个项目仍然按顺序执行：
--      gis_generate_3d_grid -> gis_electric_fence_project -> gis_mark_electric_fence。
-- ============================================================

DROP FUNCTION IF EXISTS public.gis_project_data_batch(integer, integer);

CREATE OR REPLACE FUNCTION public.gis_project_data_batch(
    p_worker_no integer,
    p_worker_count integer
)
RETURNS TABLE (
    code integer,
    msg text,
    sql_name text,
    sql_time text,
    table_name text,
    table_count text,
    exec_start timestamptz,
    exec_end timestamptz,
    exec_time numeric
)

LANGUAGE plpgsql
AS $$
DECLARE
    -- 当前分片内的项目记录。
    v_project record;

    -- 是否实际循环到项目，用于最后返回空数据提示。
    v_has_project boolean := false;
BEGIN
    -- 参数校验：总分片数必须大于 0。
    IF p_worker_count IS NULL OR p_worker_count <= 0 THEN
        RETURN QUERY SELECT
            400::integer,
            'p_worker_count 必须大于 0'::text,
            'gis_project_data_batch'::text,
            '0'::text,
            ''::text,
            '0'::text,
            NULL::timestamptz,
            NULL::timestamptz,
            0::numeric;
        RETURN;
    END IF;

    -- 参数校验：当前分片编号必须在合法范围内。
    IF p_worker_no IS NULL OR p_worker_no < 0 OR p_worker_no >= p_worker_count THEN
        RETURN QUERY SELECT
            400::integer,
            'p_worker_no 必须满足 0 <= p_worker_no < p_worker_count'::text,
            'gis_project_data_batch'::text,
            '0'::text,
            ''::text,
            '0'::text,
            NULL::timestamptz,
            NULL::timestamptz,
            0::numeric;
        RETURN;
    END IF;

    -- 按 id 哈希把项目稳定分到不同 worker，多个连接可同时执行不同分片。
    FOR v_project IN
        SELECT bp.id
        FROM public.bo_project bp
        WHERE bp.region_shape IS NOT NULL
          AND bp.del_flag = false
          AND mod(abs(hashtext(bp.id)::bigint), p_worker_count) = p_worker_no
        ORDER BY bp.id
    LOOP
        v_has_project := true;

        -- 复用单项目入口，保持单项目执行逻辑只有一份。
        RETURN QUERY
        SELECT *
        FROM public.gis_project_data(v_project.id);
    END LOOP;

    -- 当前分片没有数据时返回提示，方便检查 worker 是否跑空。
    IF NOT v_has_project THEN
        RETURN QUERY SELECT
            400::integer,
            '当前 worker 分片没有 del_flag=false 且 region_shape 不为空的项目数据'::text,
            'gis_project_data_batch'::text,
            '0'::text,
            ''::text,
            '0'::text,
            NULL::timestamptz,
            NULL::timestamptz,
            0::numeric;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.gis_project_data_batch(integer, integer) IS
'按 bo_project.id 哈希分片处理项目数据，用于多个数据库连接并行生成三维网格、电子围栏和围栏标记';
