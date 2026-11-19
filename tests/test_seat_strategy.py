"""logic.seat_strategy 选座策略、多房兜底与多账号防撞座单元测试。"""
import random

from logic.seat_strategy import (
    SeatCandidate,
    SeatClaimCoordinator,
    build_room_plan,
    normalize_seat_no,
    plan_seat_candidates,
    time_ranges_overlap,
)


def test_normalize_seat_no():
    assert normalize_seat_no("001") == "1"
    assert normalize_seat_no(" 042 ") == "42"
    assert normalize_seat_no("A-06-1") == "A-06-1"


def test_time_ranges_overlap_allows_adjacent_handoff():
    # 考研党双账号无缝衔接：09:00-15:00 与 15:00-21:00 不算冲突
    assert time_ranges_overlap("09:00", "15:00", "15:00", "21:00") is False
    assert time_ranges_overlap("9:00", "12:00", "13:00", "17:00") is False
    # 有重叠
    assert time_ranges_overlap("09:00", "15:00", "14:00", "20:00") is True
    assert time_ranges_overlap("09:00", "15:00", "09:00", "15:00") is True
    # 非法格式保守按冲突处理
    assert time_ranges_overlap("bad", "15:00", "15:00", "21:00") is True


def test_build_room_plan_deduplicates_and_preserves_order():
    plan = build_room_plan(
        "崇山校区图书馆",
        "四楼南自习室",
        fallback_rooms=[
            ("崇山校区图书馆", "四楼南自习室"),  # 重复，应跳过
            ("崇山校区图书馆", "四楼北自习室"),
            ("崇山校区图书馆", ""),             # 空房名，应跳过
            ("蒲河校区图书馆", "智慧空间"),
        ],
    )
    assert plan == [
        ("崇山校区图书馆", "四楼南自习室"),
        ("崇山校区图书馆", "四楼北自习室"),
        ("蒲河校区图书馆", "智慧空间"),
    ]


def test_plan_seat_candidates_filters_occupied_and_normalizes():
    room_seats = [
        SeatCandidate("001", "id1", "24", "free"),
        SeatCandidate("002", "id2", "24", "occupied"),
        SeatCandidate("003", "id3", "24", "free"),
        SeatCandidate("004", "id4", "24", "unavailable"),
        SeatCandidate("005", "id5", "24", "free"),
    ]

    # skip_occupied_preferred=True: 忽略已占首选 "002" 与不存在的 "999"
    pref, fb = plan_seat_candidates(
        ["002", "001", "999", "1"],
        room_seats,
        skip_occupied_preferred=True,
        shuffle_fallback=False,
    )
    assert [s.seat_no for s in pref] == ["1"]
    assert [s.seat_no for s in fb] == ["3", "5"]

    # skip_occupied_preferred=False (06:30:00 首选直击): 保留首选 "002"，但兜底仍只留 free
    pref2, fb2 = plan_seat_candidates(
        ["002", "001"],
        room_seats,
        skip_occupied_preferred=False,
        shuffle_fallback=True,
        rng=random.Random(7),
    )
    assert [s.seat_no for s in pref2] == ["2", "1"]
    assert set(s.seat_no for s in fb2) == {"3", "5"}


def test_seat_claim_coordinator_deconflicts_only_overlapping_slots():
    coord = SeatClaimCoordinator()

    # 账号 A 声明 24 房 194 号 09:00-15:00
    assert coord.try_claim("accA", "24", "0194", "09:00", "15:00") is True
    # 同一账号幂等
    assert coord.try_claim("accA", "24", "194", "09:00", "15:00") is True
    # 账号 B 重叠时段 -> 拒绝，防止双账号撞座
    assert coord.try_claim("accB", "24", "194", "12:00", "18:00") is False
    # 账号 C 无缝衔接时段 (15:00-21:00) -> 放行！
    assert coord.try_claim("accC", "24", "194", "15:00", "21:00") is True

    # 账号 A 释放后，账号 B 可以声明
    coord.release("accA", "24", "194")
    assert coord.try_claim("accB", "24", "194", "12:00", "15:00") is True

    # release_all 彻底清空该账号全部占位
    coord.release_all("accB")
    assert coord.try_claim("accA", "24", "194", "12:00", "14:00") is True
