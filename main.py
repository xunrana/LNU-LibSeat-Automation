"""LNU-LibSeat v6 纯 API CLI 入口（委托 ``logic.orchestrator`` 执行）。"""
from __future__ import annotations

import threading

import core.utils as utils
from logic.orchestrator import (
    KEEPALIVE_LEAD_SECONDS,
    MAINTENANCE_RETRY_INTERVAL_SECONDS,
    PREP_LEAD_SECONDS,
    build_custom_schedule,
    export_session_log as _export_session_log,
    run_all_accounts,
    run_api_session,
    setup_session_dir as _setup_session_dir,
    start_captcha_model_preload as _start_captcha_model_preload,
    thread_task,
    wait_until,
)

__all__ = [
    "KEEPALIVE_LEAD_SECONDS",
    "MAINTENANCE_RETRY_INTERVAL_SECONDS",
    "PREP_LEAD_SECONDS",
    "build_custom_schedule",
    "main",
    "run_api_session",
    "thread_task",
    "utils",
    "wait_until",
    "_setup_session_dir",
    "_export_session_log",
    "_start_captcha_model_preload",
]


def main(stop_event: threading.Event | None = None) -> None:
    """主入口：支持从 PySide6 GUI Worker 传入 ``stop_event`` 实现优雅停止。"""
    run_all_accounts(stop_event=stop_event)


if __name__ == "__main__":
    main()
