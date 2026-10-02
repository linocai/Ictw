"""Build71 memory recovery, abnormal completions and override ABA regressions."""
import json
import pytest
from sqlalchemy import select
import app.db as db_module
from app.models import Book, Chapter, Character, ChapterCharacter, CharacterEvent, CharacterStateChange
from app.services.context import memory_candidates
from app.services.character_state_projection import rebuild_book_projection
from app.services.project_packages import export_project_package, import_project_package, ProjectPackageError, _validated_records, _read_project_package
from app.llm.base import LLMError
from app.llm.factory import get_writer_client, get_checker_client
from test_build70_writer_pipeline import _llm, _install_streams, _stream_lines, HALF_SENTENCE, CountingChecker, _manuscript

@pytest.mark.parametrize('finish,code', [('length','llm_output_truncated'),('content_filter','llm_content_blocked'),('RECITATION','llm_invalid_finish'),('tool_calls','llm_invalid_finish')])
@pytest.mark.parametrize('method', ['complete_json','complete'])
def test_nonempty_content_never_hides_abnormal_finish(monkeypatch, finish, code, method):
    llm=_llm()
    monkeypatch.setattr(llm, '_post', lambda *a, **kw: {'choices':[{'message':{'content':'{"verdict":"passed","issues":[],"name_uses":[]}'},'finish_reason':finish}]})
    with pytest.raises(LLMError) as e:
        getattr(llm,method)(system='s',user='u',**({'schema':{}} if method=='complete_json' else {}))
    assert e.value.code==code

@pytest.mark.parametrize('reason,expected', [('content_policy_violation','llm_content_blocked'),('rate_limit_error','llm_rate_limited'),('unknown_sensitive_message','llm_upstream_error')])
def test_sse_error_is_not_washed_by_done(client,auth_headers,wait_for_terminal,monkeypatch,reason,expected):
    _,_,chapter=_manuscript(client,auth_headers)
    lines=list(_stream_lines(HALF_SENTENCE,usage=False))+['data: '+json.dumps({'error':{'code':reason,'message':'sensitive-raw-data'}}),'data: [DONE]']
    calls=_install_streams(monkeypatch,[lines]); llm=_llm(); checker=CountingChecker()
    client.app.dependency_overrides[get_writer_client]=lambda:llm
    client.app.dependency_overrides[get_checker_client]=lambda:checker
    r=client.post(f"/api/v1/chapters/{chapter['id']}/write",headers=auth_headers,json={});r.raise_for_status()
    terminal=wait_for_terminal(client,chapter['id'],auth_headers)
    assert terminal['phase']=='failed' and terminal['error_code']==expected
    assert len(calls)==1 and checker.calls==0 and 'sensitive-raw-data' not in json.dumps(terminal)
    assert client.get(f"/api/v1/chapters/{chapter['id']}",headers=auth_headers).json()['draft_text']=='合成原稿。'

@pytest.mark.parametrize('kind', ['agent-personas','agent-model-bindings'])
def test_deleted_override_revision_cannot_be_reused(client,auth_headers,kind):
    book=client.post('/api/v1/books',headers=auth_headers,json={'title':'ABA'}).json()
    if kind=='agent-personas': payload={'editable_persona':'新人格'}
    else:
        profile=client.post('/api/v1/llm_profiles',headers=auth_headers,json={'name':'fixture','base_url':'https://synthetic.invalid','api_key':'synthetic','model_name':'glm-5'}).json()
        payload={'llm_profile_id':profile['id'],'thinking_enabled':False,'temperature':.8}
    path=f"/api/v1/books/{book['id']}/{kind}/writer"
    def headers(rev): return {**auth_headers,'If-Match':str(rev)}
    first=client.put(path,headers=headers(0),json=payload);first.raise_for_status();old=first.json()['content_revision']
    for _ in range(3):
        result=client.put(path,headers=headers(old),json=payload);result.raise_for_status();old=result.json()['content_revision']
    for _ in range(2):
        assert client.delete(path,headers=headers(old)).status_code==204
        new=client.put(path,headers=headers(0),json=payload);new.raise_for_status()
        assert new.json()['content_revision']>old
        assert client.put(path,headers=headers(old),json=payload).status_code==409
        assert client.delete(path,headers=headers(old)).status_code==409
        old=new.json()['content_revision']


def test_legacy_roundtrip_preserves_memory_and_rejects_invalid_links(client):
    with db_module.SessionLocal() as db:
        b=Book(title='旧记忆');db.add(b);db.flush();p=Character(book_id=b.id,name='林夕');db.add(p);db.flush()
        c=Chapter(book_id=b.id,index=1,status='finalized',draft_text='林夕出发。',long_summary='去旧城',legacy_archive_eligible=True,archive_status='legacy');db.add(c);db.flush()
        later=Chapter(book_id=b.id,index=2);db.add(later);db.flush()
        db.add_all([ChapterCharacter(chapter_id=c.id,character_id=p.id),ChapterCharacter(chapter_id=later.id,character_id=p.id),CharacterEvent(book_id=b.id,chapter_id=c.id,character_id=p.id,event_text='独有行动'),CharacterStateChange(book_id=b.id,chapter_id=c.id,character_id=p.id,scope='persistent',slot='当前目标',operation='set',value='旧城',batch_id='',evidence='出发')]);db.flush();rebuild_book_projection(db,b.id);db.commit()
        before=[x.text for x in memory_candidates(db,later)]
        package=export_project_package(db,b);restored,warnings=import_project_package(db,package)
        cs=db.scalars(select(Chapter).where(Chapter.book_id==restored.id).order_by(Chapter.index)).all()
        people=db.scalars(select(Character).where(Character.book_id==restored.id)).all()
        assert warnings==[] and cs[0].legacy_archive_eligible
        assert people[0].dynamic_fields=={'当前目标':'旧城'}
        assert [x.text for x in memory_candidates(db,cs[1])]==before
        decoded=_read_project_package(package);decoded['chapters.json'][0]['legacy_memory']['states'][0]['character_id']='missing'
        with pytest.raises(ProjectPackageError,match='unknown character'): _validated_records(decoded)
        c.legacy_archive_eligible=False;db.commit()
        assert _read_project_package(export_project_package(db,b))['chapters.json'][0]['legacy_memory'] is None


def test_revision_ledger_migration_preserves_books_and_requires_backup_for_downgrade(tmp_path, monkeypatch):
    import sqlite3
    from alembic import command
    from app.config import get_settings
    from test_migration_safety import _upgrade_to, _authorize, _sha256
    path, config = _upgrade_to(tmp_path, monkeypatch, '20260923_0014')
    try:
        with sqlite3.connect(path) as db:
            db.execute("INSERT INTO books (id,title,world_setting,created_at,updated_at) VALUES ('book','原书','原世界','2026-09-01','2026-09-01')")
        command.upgrade(config, '20260929_0015')
        with sqlite3.connect(path) as db:
            assert db.execute('SELECT title,world_setting FROM books').fetchall()==[('原书','原世界')]
            db.execute("INSERT INTO book_override_revisions VALUES ('book','persona','writer',19)")
            assert db.execute('PRAGMA integrity_check').fetchall()==[('ok',)]
            assert db.execute('PRAGMA foreign_key_check').fetchall()==[]
        before = _sha256(path)
        with pytest.raises(RuntimeError, match='destructive downgrade refused'):
            command.downgrade(config, '20260923_0014')
        assert _sha256(path)==before
        _authorize(monkeypatch,path,['20260929_0015'])
        command.downgrade(config,'20260923_0014')
        command.upgrade(config,'20260929_0015')
        with sqlite3.connect(path) as db:
            assert db.execute('SELECT title FROM books').fetchall()==[('原书',)]
            db.execute('PRAGMA foreign_keys=ON')
            db.execute("INSERT INTO book_override_revisions VALUES ('book','model','writer',20)")
            db.execute("DELETE FROM books WHERE id='book'")
            assert db.execute('SELECT * FROM book_override_revisions').fetchall()==[]
            assert db.execute('PRAGMA foreign_key_check').fetchall()==[]
    finally:
        get_settings.cache_clear()
