"""The batch schedule set from the ETL console (etl.etl_schedule)."""
import pytest

from conftest import ADMIN, one
from etl.run import run

pytestmark = pytest.mark.skipif(not ADMIN, reason="TEST_POSTGRES_URL not set")


def runs(wh):
    return one(wh, "select count(*) from etl.etl_run_log where status <> 'skipped'")


def test_scheduler_start_runs_when_due_and_records_a_heartbeat(env):
    settings, src, wh = env
    assert run(settings, "schedule") == 0
    assert runs(wh) == 1
    assert one(wh, "select last_heartbeat_at is not null from etl.etl_schedule")
    # every minute by default: a second start right away is not due yet
    assert run(settings, "schedule") == 0
    assert runs(wh) == 1


def test_paused_schedule_runs_nothing_but_manual_runs_still_work(env):
    settings, src, wh = env
    wh.execute("select console.set_schedule(false, 15, 'gopi@example.com')")
    assert run(settings, "schedule") == 0
    assert runs(wh) == 0
    assert one(wh, "select scheduler_alive from analytics.vw_etl_schedule")
    assert one(wh, "select next_run_due_at from analytics.vw_etl_schedule") is None
    assert run(settings, "manual") == 0
    assert runs(wh) == 1


def test_run_now_is_served_once_even_while_paused(env):
    settings, src, wh = env
    wh.execute("select console.set_schedule(false, 60, 'gopi@example.com')")
    wh.execute("select console.request_run('gopi@example.com')")
    assert run(settings, "schedule") == 0
    assert one(wh, "select triggered_by from etl.etl_run_log order by run_id desc limit 1") == "console"
    assert one(wh, "select run_requested_at from etl.etl_schedule") is None
    assert run(settings, "schedule") == 0          # request used up, schedule paused
    assert runs(wh) == 1
    actions = [r[0] for r in wh.execute("select action from etl.etl_console_actions order by action_id")]
    assert actions == ["schedule paused", "run requested"]


def test_longer_interval_waits(env):
    settings, src, wh = env
    wh.execute("select console.set_schedule(true, 60, 'gopi@example.com')")
    run(settings, "schedule")
    wh.execute("update etl.etl_run_log set started_at = started_at - interval '30 minutes'")
    run(settings, "schedule")
    assert runs(wh) == 1                            # 30 min < 60 min
    wh.execute("update etl.etl_run_log set started_at = started_at - interval '31 minutes'")
    run(settings, "schedule")
    assert runs(wh) == 2


def test_run_steps_view_shows_rows_per_target(env):
    settings, src, wh = env
    run(settings, "manual")
    rows = dict(wh.execute("select target, rows_inserted from analytics.vw_etl_run_steps where step = 'dw'").fetchall())
    assert rows["dw.fact_purchase_orders"] == 2
    assert one(wh, "select rows_read from analytics.vw_etl_run_steps where step = 'extract'") == 9   # all 9 seed rows


def test_console_functions_validate_input(env):
    settings, src, wh = env
    with pytest.raises(Exception):
        wh.execute("select console.set_schedule(true, 7, 'gopi@example.com')")   # 7 min is not an allowed interval
    with pytest.raises(Exception):
        wh.execute("select console.request_run('')")
