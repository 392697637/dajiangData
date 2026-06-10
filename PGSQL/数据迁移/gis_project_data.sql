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
--
-- 使用示例：
--   SELECT * FROM gis_project_data();
--   SELECT * FROM gis_project_data('2c95908e9aed844e019aeda0440f0455');
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

            RETURN QUERY SELECT
                COALESCE(v_result.code, 500)::integer,
                COALESCE(v_result.msg, '')::text,
                'gis_generate_3d_grid'::text,
                ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_start_time)::numeric, 3)::text,
                COALESCE(v_result.table_name, '')::text,
                COALESCE(v_result.count, 0)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                500::integer,
                SQLERRM::text,
                'gis_generate_3d_grid'::text,
                ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_start_time)::numeric, 3)::text,
                ''::text,
                '0'::text;
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

            RETURN QUERY SELECT
                COALESCE(v_result.code, 500)::integer,
                COALESCE(v_result.msg, '')::text,
                'gis_electric_fence_project'::text,
                ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_start_time)::numeric, 3)::text,
                COALESCE(v_result.table_name, '')::text,
                COALESCE(v_result.count, 0)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                500::integer,
                SQLERRM::text,
                'gis_electric_fence_project'::text,
                ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_start_time)::numeric, 3)::text,
                ''::text,
                '0'::text;
        END;

        -- 3. 根据项目电子围栏刷新三维网格点的围栏标记。
        BEGIN
            v_start_time := clock_timestamp();

            SELECT *
            INTO v_result
            FROM public.gis_mark_electric_fence(v_project.id);

            RETURN QUERY SELECT
                COALESCE(v_result.code, 500)::integer,
                COALESCE(v_result.msg, '')::text,
                'gis_mark_electric_fence'::text,
                ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_start_time)::numeric, 3)::text,
                COALESCE(v_result.table_name, '')::text,
                COALESCE(v_result.count, 0)::text;
        EXCEPTION WHEN OTHERS THEN
            RETURN QUERY SELECT
                500::integer,
                SQLERRM::text,
                'gis_mark_electric_fence'::text,
                ROUND(EXTRACT(EPOCH FROM clock_timestamp() - v_start_time)::numeric, 3)::text,
                ''::text,
                '0'::text;
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
            '0'::text;
    END IF;
END;
$$;

COMMENT ON FUNCTION public.gis_project_data(text) IS
'循环读取 bo_project.id 和 region_shape，生成三维网格、项目电子围栏并刷新围栏标记';
