 ---------------------------------------------bo_electric_fence-------------------------------------------

-- ----------------------------
-- Table structure for bo_electric_fence
-- ----------------------------
DROP TABLE IF EXISTS "public"."bo_electric_fence";
CREATE TABLE "public"."bo_electric_fence" (
  "id" varchar(65535) COLLATE "pg_catalog"."default" NOT NULL,
  "create_time" timestamp(6) NOT NULL,
  "create_user" varchar(32) COLLATE "pg_catalog"."default",
  "del_flag" bool NOT NULL DEFAULT false,
  "remark" varchar(1000) COLLATE "pg_catalog"."default",
  "update_time" timestamp(6) NOT NULL,
  "update_user" varchar(32) COLLATE "pg_catalog"."default",
  "project_id" varchar(65535) COLLATE "pg_catalog"."default",
  "code" varchar(255) COLLATE "pg_catalog"."default",
  "status" varchar(65535) COLLATE "pg_catalog"."default",
  "name" varchar(200) COLLATE "pg_catalog"."default",
  "type" varchar(32) COLLATE "pg_catalog"."default",
  "frequency" varchar(65535) COLLATE "pg_catalog"."default",
  "area" varchar(255) COLLATE "pg_catalog"."default",
  "week" varchar(255) COLLATE "pg_catalog"."default",
  "day" varchar(255) COLLATE "pg_catalog"."default",
  "start_time" varchar(32) COLLATE "pg_catalog"."default",
  "end_time" varchar(32) COLLATE "pg_catalog"."default",
  "draw_method" varchar(65535) COLLATE "pg_catalog"."default",
  "height" float8,
  "fence_type" varchar(20) COLLATE "pg_catalog"."default",
  "use_enabled" bool NOT NULL DEFAULT true,
  "geom" geometry(GEOMETRY),
  "time_plan" varchar(4000) COLLATE "pg_catalog"."default"
)
;
COMMENT ON COLUMN "public"."bo_electric_fence"."id" IS '主键';
COMMENT ON COLUMN "public"."bo_electric_fence"."create_time" IS '创建时间';
COMMENT ON COLUMN "public"."bo_electric_fence"."create_user" IS '创建者';
COMMENT ON COLUMN "public"."bo_electric_fence"."del_flag" IS '是否删除：t删除；f未删除';
COMMENT ON COLUMN "public"."bo_electric_fence"."remark" IS '备注';
COMMENT ON COLUMN "public"."bo_electric_fence"."update_time" IS '更新时间';
COMMENT ON COLUMN "public"."bo_electric_fence"."update_user" IS '更新者';
COMMENT ON COLUMN "public"."bo_electric_fence"."project_id" IS '项目id';
COMMENT ON COLUMN "public"."bo_electric_fence"."code" IS '编号';
COMMENT ON COLUMN "public"."bo_electric_fence"."status" IS '状态';
COMMENT ON COLUMN "public"."bo_electric_fence"."name" IS '名称';
COMMENT ON COLUMN "public"."bo_electric_fence"."type" IS '类型 1:越界闯入 2:越界离开';
COMMENT ON COLUMN "public"."bo_electric_fence"."frequency" IS '执行频率 1:每天 2:每周 3:每月';
COMMENT ON COLUMN "public"."bo_electric_fence"."area" IS '面积';
COMMENT ON COLUMN "public"."bo_electric_fence"."week" IS '开始时间cron';
COMMENT ON COLUMN "public"."bo_electric_fence"."day" IS '结束时间cron';
COMMENT ON COLUMN "public"."bo_electric_fence"."start_time" IS '开始时间';
COMMENT ON COLUMN "public"."bo_electric_fence"."end_time" IS '结束时间';
COMMENT ON COLUMN "public"."bo_electric_fence"."draw_method" IS '绘制方式';
COMMENT ON COLUMN "public"."bo_electric_fence"."height" IS '围栏高度';
COMMENT ON COLUMN "public"."bo_electric_fence"."fence_type" IS '电子围栏类型';
COMMENT ON COLUMN "public"."bo_electric_fence"."use_enabled" IS '是否启用';
COMMENT ON COLUMN "public"."bo_electric_fence"."geom" IS '空间数据';
COMMENT ON COLUMN "public"."bo_electric_fence"."time_plan" IS '时间计划';
COMMENT ON TABLE "public"."bo_electric_fence" IS '电子围栏信息';


---------------------------------------------bo_ground_ele-------------------------------------------

DROP TABLE IF EXISTS "public"."bo_ground_ele";
CREATE TABLE "public"."bo_ground_ele" (
  "id" varchar(32) COLLATE "pg_catalog"."default" NOT NULL,
  "create_time" timestamp(6) NOT NULL DEFAULT now(),
  "create_user" varchar(32) COLLATE "pg_catalog"."default",
  "del_flag" bool NOT NULL DEFAULT false,
  "remark" varchar(1024) COLLATE "pg_catalog"."default",
  "update_time" timestamp(6) NOT NULL DEFAULT now(),
  "update_user" varchar(32) COLLATE "pg_catalog"."default",
  "analysis_url" varchar(512) COLLATE "pg_catalog"."default",
  "analysis_way" varchar(8) COLLATE "pg_catalog"."default",
  "danger_level" varchar(8) COLLATE "pg_catalog"."default",
  "danger_level_name" varchar(32) COLLATE "pg_catalog"."default",
  "description" varchar(1024) COLLATE "pg_catalog"."default",
  "enabled" bool NOT NULL,
  "ground_ele_code" varchar(32) COLLATE "pg_catalog"."default",
  "ground_ele_name" varchar(32) COLLATE "pg_catalog"."default",
  "layer_code" varchar(32) COLLATE "pg_catalog"."default",
  "linkman" varchar(32) COLLATE "pg_catalog"."default",
  "linkman_phone" varchar(32) COLLATE "pg_catalog"."default",
  "location" varchar(1024) COLLATE "pg_catalog"."default",
  "project_id" varchar(32) COLLATE "pg_catalog"."default",
  "protect_way" varchar(8) COLLATE "pg_catalog"."default",
  "protect_way_name" varchar(32) COLLATE "pg_catalog"."default",
  "range_unit" varchar(32) COLLATE "pg_catalog"."default",
  "range_value" numeric(18,4),
  "release_id" varchar(32) COLLATE "pg_catalog"."default",
  "img_path" varchar(1024) COLLATE "pg_catalog"."default",
  "length" varchar(10) COLLATE "pg_catalog"."default",
  "sign_time" timestamp(6),
  "is_hot" bool,
  "geom" geometry(GEOMETRY)
)
;
COMMENT ON COLUMN "public"."bo_ground_ele"."id" IS '主键';
COMMENT ON COLUMN "public"."bo_ground_ele"."create_time" IS '创建时间';
COMMENT ON COLUMN "public"."bo_ground_ele"."create_user" IS '创建者';
COMMENT ON COLUMN "public"."bo_ground_ele"."del_flag" IS '是否删除：false未删除；true删除';
COMMENT ON COLUMN "public"."bo_ground_ele"."remark" IS '备注';
COMMENT ON COLUMN "public"."bo_ground_ele"."update_time" IS '更新时间';
COMMENT ON COLUMN "public"."bo_ground_ele"."update_user" IS '更新者';
COMMENT ON COLUMN "public"."bo_ground_ele"."analysis_url" IS '视频地址';
COMMENT ON COLUMN "public"."bo_ground_ele"."analysis_way" IS '视频协议类型 字典2012';
COMMENT ON COLUMN "public"."bo_ground_ele"."danger_level" IS '危险级别 字典2010';
COMMENT ON COLUMN "public"."bo_ground_ele"."danger_level_name" IS '危险级别';
COMMENT ON COLUMN "public"."bo_ground_ele"."description" IS '描述';
COMMENT ON COLUMN "public"."bo_ground_ele"."enabled" IS '是否启用：1启用；0禁用';
COMMENT ON COLUMN "public"."bo_ground_ele"."ground_ele_code" IS '地物要素编码';
COMMENT ON COLUMN "public"."bo_ground_ele"."ground_ele_name" IS '地物要素名称';
COMMENT ON COLUMN "public"."bo_ground_ele"."layer_code" IS '图层code';
COMMENT ON COLUMN "public"."bo_ground_ele"."linkman" IS '联系人';
COMMENT ON COLUMN "public"."bo_ground_ele"."linkman_phone" IS '联系电话';
COMMENT ON COLUMN "public"."bo_ground_ele"."location" IS '位置';
COMMENT ON COLUMN "public"."bo_ground_ele"."project_id" IS '项目id';
COMMENT ON COLUMN "public"."bo_ground_ele"."protect_way" IS '保护方式 字典2011';
COMMENT ON COLUMN "public"."bo_ground_ele"."protect_way_name" IS '保护方式';
COMMENT ON COLUMN "public"."bo_ground_ele"."range_unit" IS '范围单位';
COMMENT ON COLUMN "public"."bo_ground_ele"."range_value" IS '范围值';
COMMENT ON COLUMN "public"."bo_ground_ele"."release_id" IS '地图发布id';
COMMENT ON COLUMN "public"."bo_ground_ele"."img_path" IS '附件路径，分割';
COMMENT ON COLUMN "public"."bo_ground_ele"."length" IS '长度';
COMMENT ON COLUMN "public"."bo_ground_ele"."sign_time" IS '标注时间';
COMMENT ON COLUMN "public"."bo_ground_ele"."is_hot" IS '是否热点';
COMMENT ON TABLE "public"."bo_ground_ele" IS '地物标注信息';
