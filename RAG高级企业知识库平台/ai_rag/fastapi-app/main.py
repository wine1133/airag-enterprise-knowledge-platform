import asyncio
import os
import sys
from contextlib import asynccontextmanager

import jieba
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.cors import CORSMiddleware
from starlette.middleware.gzip import GZipMiddleware
from tortoise.contrib.fastapi import RegisterTortoise, tortoise_exception_handlers

from api import api_router
from common.exception_handler import setup_exceptions
from common.result import Result
from settings import TORTOISE_ORM

# 前端构建产物目录。开发时前端由 Vite 单独跑，这个目录不存在，下面的静态托管会自动跳过；
# 生产部署先 npm run build，再由后端把整个前端一起提供，公网只需要暴露 9090 一个端口。
FRONTEND_DIST = os.path.abspath(
    os.environ.get("FRONTEND_DIST", os.path.join(os.path.dirname(__file__), "..", "vue", "dist"))
)

# 这些前缀是真实接口，SPA 兜底路由不能把它们吞成 index.html
API_PREFIXES = (
    "currentUser", "updatePassword", "user", "files",
    "knowledgeBase", "knowledgeDocument", "knowledgeChunk", "chunkStrategy",
    "aiModelConfig", "promptTemplate", "functionTool", "agent", "retrieval",
    "retrievalStrategy", "vectorize", "qaApp", "feedback", "evalDataset",
    "evalTask", "evalReport", "docs", "openapi.json", "redoc",
)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """应用启动时连接数据库、预热分词器，关闭时释放连接。"""
    # jieba 第一次分词时才加载词典，要一两秒。BM25 检索每次都要分词，
    # 不预热的话这段耗时会落在用户的第一次提问上，这里挪到启动阶段。
    # 加载是纯 CPU 的同步操作，丢到线程里跑，不占事件循环。
    await asyncio.to_thread(jieba.initialize)
    async with RegisterTortoise(app, config=TORTOISE_ORM):
        yield


app = FastAPI(
    title="AIRAG高级企业知识库平台",
    lifespan=lifespan,
    # ORM 层的异常（记录不存在、唯一键冲突等）交给 Tortoise 自带的处理器
    exception_handlers=tortoise_exception_handlers(),
)

# 跨域配置 CORS。前端跑在 5173 端口、后端在 9090，属于跨域请求，
# 不配的话浏览器会拦掉所有接口调用
app.add_middleware(
    CORSMiddleware,
    # 允许所有源
    allow_origins=["*"],
    # 允许所有 HTTP 方法
    allow_methods=["*"],
    # 允许所有请求头，前端要带自定义的 token 头
    allow_headers=["*"],
)

# 生产环境前端资源包较大，开 gzip 后 1.2MB 的 JS 压到 400KB 左右，公网隧道和慢网络下才不会加载到一半断掉
app.add_middleware(GZipMiddleware, minimum_size=1024)

# 注册全部业务路由
app.include_router(api_router)
# 注册统一异常处理器
setup_exceptions(app)


@app.get("/")
async def root():
    # 生产模式下根路径直接返回前端首页，方便用 / 判断服务是否活着
    index_file = os.path.join(FRONTEND_DIST, "index.html")
    if os.path.isfile(index_file):
        return FileResponse(index_file)
    return Result.success()


if os.path.isdir(FRONTEND_DIST):
    assets_dir = os.path.join(FRONTEND_DIST, "assets")
    if os.path.isdir(assets_dir):
        app.mount("/assets", StaticFiles(directory=assets_dir), name="assets")

    @app.get("/{full_path:path}", include_in_schema=False)
    async def spa_fallback(full_path: str):
        """Vue 用的是 history 路由，刷新 /manager/home 这类地址要回落到 index.html。"""
        first_segment = full_path.split("/", 1)[0]
        if first_segment in API_PREFIXES:
            raise HTTPException(status_code=404, detail="Not Found")
        root_dir = os.path.realpath(FRONTEND_DIST)
        candidate = os.path.realpath(os.path.join(root_dir, full_path))
        if full_path and candidate.startswith(root_dir) and os.path.isfile(candidate):
            return FileResponse(candidate)
        return FileResponse(os.path.join(root_dir, "index.html"))


def loop_factory() -> asyncio.AbstractEventLoop:
    """指定事件循环类型，交给 uvicorn 用来创建循环。

    Windows 上 Python 默认用 ProactorEventLoop，而向量库用的 psycopg
    异步模式不支持它，一连接就报：

        Psycopg cannot use the 'ProactorEventLoop' to run in async mode

    所以 Windows 上必须换成 SelectorEventLoop。uvicorn 只在开了 reload
    的时候才会自己换成 Selector，一旦有人把 reload 关掉，向量检索就会
    在运行时突然连不上库，所以这里显式指定，不依赖 reload 的副作用。
    """
    if sys.platform == "win32":
        return asyncio.SelectorEventLoop()
    return asyncio.new_event_loop()


if __name__ == "__main__":
    # 生产部署用 `python -m uvicorn main:app --host 0.0.0.0 --port 9090 --loop main:loop_factory`
    uvicorn.run(
        "main:app",
        host=os.environ.get("HOST", "localhost"),
        reload=os.environ.get("RELOAD", "1") == "1",
        port=int(os.environ.get("PORT", "9090")),
        loop="main:loop_factory",
    )
