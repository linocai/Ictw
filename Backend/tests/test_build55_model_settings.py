"""Book settings UI payloads must match runtime capabilities before binding."""
import pytest


@pytest.mark.parametrize("model,role,thinking,effort,temperature,effective", [
    ("deepseek-flash", "writer", True, "high", None, True),
    ("deepseek-flash", "writer", False, None, 0.7, False),
    ("glm-5", "writer", True, "max", 0.4, True),
    ("gemini-3.5-flash", "writer", None, "medium", None, True),
    ("custom-model", "writer", None, None, 0.6, None),
    ("deepseek-flash", "extractor", False, None, 0.2, False),
    ("glm-5", "inspiration_creator", False, None, 0.2, False),
])
def test_profile_capabilities_and_book_ui_payload_roundtrip(client, auth_headers, model, role, thinking, effort, temperature, effective):
    profile_response = client.post('/api/v1/llm_profiles', headers=auth_headers, json={
        'name': 'test', 'base_url': 'https://example.test', 'api_key': 'synthetic-key', 'model_name': model,
    })
    assert profile_response.status_code == 201
    profile = profile_response.json()
    from app.services.model_capabilities import resolve_capabilities
    assert profile['capabilities'] == resolve_capabilities(model, 'https://example.test').as_dict()
    listed = client.get('/api/v1/llm_profiles', headers=auth_headers).json()
    assert next(p for p in listed if p['id'] == profile['id'])['capabilities'] == profile['capabilities']
    book = client.post('/api/v1/books', headers=auth_headers, json={'title': 'test'}).json()
    payload = dict(llm_profile_id=profile['id'], thinking_enabled=thinking, reasoning_effort=effort, temperature=temperature)
    saved = client.put(f"/api/v1/books/{book['id']}/agent-model-bindings/{role}",
                       headers={**auth_headers, 'If-Match': '0'}, json=payload)
    assert saved.status_code == 200, saved.text
    values = saved.json()['effective_binding']
    assert values['effective_thinking_enabled'] is effective
    assert values['effective_temperature'] == temperature
    assert values['effective_reasoning_effort'] == effort


def test_editing_profile_refreshes_capabilities_without_binding(client, auth_headers):
    profile = client.post('/api/v1/llm_profiles', headers=auth_headers, json={
        'name': 'test', 'base_url': 'https://example.test', 'api_key': 'synthetic-key', 'model_name': 'deepseek-flash',
    }).json()
    edited = client.patch(f"/api/v1/llm_profiles/{profile['id']}", headers=auth_headers,
                          json={'model_name': 'gemini-3.5-flash'})
    assert edited.status_code == 200
    assert edited.json()['capabilities']['thinking_required'] is True
    read = client.get(f"/api/v1/llm_profiles/{profile['id']}", headers=auth_headers).json()
    assert read['capabilities'] == edited.json()['capabilities']
    assert 'api_key' not in read and 'api_key_encrypted' not in read
