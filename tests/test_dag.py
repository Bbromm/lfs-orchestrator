"""Тесты DAG-планировщика."""
import pytest
from lfs_orchestrator.dag import DAG, DAGError
from lfs_orchestrator.task import Task, TaskState


def test_simple_chain():
    tasks = [
        Task(name="a", script="a.sh", phase="p"),
        Task(name="b", script="b.sh", phase="p", deps=["p/a"]),
        Task(name="c", script="c.sh", phase="p", deps=["p/b"]),
    ]
    dag = DAG(tasks)
    order = dag.topological_order()
    assert order.index("p/a") < order.index("p/b") < order.index("p/c")


def test_cycle_detection():
    tasks = [
        Task(name="a", script="a.sh", phase="p", deps=["p/b"]),
        Task(name="b", script="b.sh", phase="p", deps=["p/a"]),
    ]
    with pytest.raises(DAGError, match="цикл"):
        DAG(tasks)


def test_missing_dep():
    tasks = [Task(name="a", script="a.sh", phase="p", deps=["p/nonexistent"])]
    with pytest.raises(DAGError, match="несуществующую"):
        DAG(tasks)


def test_ready_tasks_parallel():
    tasks = [
        Task(name="a", script="a.sh", phase="p"),
        Task(name="b", script="b.sh", phase="p"),
        Task(name="c", script="c.sh", phase="p", deps=["p/a", "p/b"]),
    ]
    dag = DAG(tasks)
    ready = dag.ready_tasks(set())
    names = {t.name for t in ready}
    assert names == {"a", "b"}  # c заблокирован