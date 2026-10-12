let MODELS = {};
try {
  MODELS = JSON.parse(require('fs').readFileSync('/etc/llama-router/models.json'));
} catch (e) {
}

async function routeRequest(r) {
  let body;
  try {
    body = JSON.parse(r.requestText || '{}');
  } catch (e) {
    r.return(400, '{"error":{"message":"invalid JSON body","type":"invalid_request_error"}}\n');
    return;
  }

  const requested = body.model || '_default';
  const target = MODELS[requested];

  if (!target) {
    r.return(404, JSON.stringify({
      error: {
        message: 'model not found: ' + requested,
        type: 'invalid_request_error',
        param: 'model',
        available: Object.keys(MODELS).filter(k => k !== '_default'),
      },
    }) + '\n');
    return;
  }

  const named = '@backend_' + target.replace(/[^a-zA-Z0-9_]/g, '_');
  r.internalRedirect(named);
}

async function listModels(r) {
  const ids = Object.keys(MODELS).filter(k => k !== '_default');
  const now = Math.floor(Date.now() / 1000);
  r.headersOut['Content-Type'] = 'application/json';
  r.return(200, JSON.stringify({
    object: 'list',
    data: ids.map(id => ({
      id: id,
      object: 'model',
      created: now,
      owned_by: 'llama-server',
    })),
  }) + '\n');
}

export default { routeRequest, listModels };
