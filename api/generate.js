const DEFAULT_BASE_URL = 'https://api.openai.com/v1';
const DEFAULT_MODEL = 'gpt-4o-mini';
const REQUEST_TIMEOUT_MS = 290000;

function normalizeOpenAIBase(raw) {
  const fallback = DEFAULT_BASE_URL;
  const input = String(raw || fallback).trim() || fallback;
  const withoutChat = input.replace(/\/chat\/completions\/?$/i, '').replace(/\/+$/, '');

  try {
    const url = new URL(withoutChat);
    url.hash = '';
    url.search = '';

    const versionPath = url.pathname.match(/^(.*?\/v\d+)(?:\/.*)?$/i);
    if (versionPath) {
      url.pathname = versionPath[1];
      return url.toString().replace(/\/+$/, '');
    }

    const cleanPath = url.pathname.replace(/\/+$/, '');
    const dashboardPath = !cleanPath || cleanPath === '/' || /\/(?:login|dashboard|console|admin|app|home)$/i.test(cleanPath);
    url.pathname = (dashboardPath ? '' : cleanPath) + '/v1';
    return url.toString().replace(/\/+$/, '');
  } catch (_error) {
    return withoutChat || fallback;
  }
}

function chatUrlFromBase(baseUrl) {
  const b = normalizeOpenAIBase(baseUrl);
  return /\/chat\/completions$/i.test(b) ? b : `${b}/chat/completions`;
}

function originV1ChatUrl(baseUrl) {
  try {
    return `${new URL(baseUrl).origin}/v1/chat/completions`;
  } catch (_error) {
    return '';
  }
}

function looksLikeHtml(text, contentType = '') {
  const sample = String(text || '').trim().slice(0, 500).toLowerCase();
  return String(contentType || '').toLowerCase().includes('text/html') ||
    sample.startsWith('<!doctype html') ||
    sample.startsWith('<html') ||
    sample.includes('<div id="app"></div>') ||
    sample.includes('<title>sub2api') ||
    sample.includes('gateway time-out');
}

function htmlTitle(text) {
  const title = (String(text || '').match(/<title[^>]*>([\s\S]*?)<\/title>/i) || [])[1];
  return title ? title.replace(/\s+/g, ' ').trim().slice(0, 140) : 'no title';
}

function parseJsonLoose(text) {
  try {
    return JSON.parse(text);
  } catch (_error) {
    return null;
  }
}

function parseSse(text) {
  const payloads = String(text || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith('data:'))
    .map((line) => line.slice(5).trim())
    .filter((payload) => payload && payload !== '[DONE]');

  if (!payloads.length) return null;

  let lastJson = null;
  const chunks = [];
  for (const payload of payloads) {
    const json = parseJsonLoose(payload);
    if (!json) continue;
    lastJson = json;
    const textChunk = json?.choices?.[0]?.delta?.content ||
      json?.choices?.[0]?.message?.content ||
      json?.choices?.[0]?.text ||
      json?.output_text ||
      json?.text ||
      json?.content ||
      '';
    if (textChunk) chunks.push(String(textChunk));
  }

  if (chunks.length) return { choices: [{ message: { content: chunks.join('') } }] };
  return lastJson;
}

async function readUpstream(response, url) {
  const contentType = response.headers.get('content-type') || '';
  const text = await response.text();
  const json = parseJsonLoose(text) || parseSse(text);

  return {
    ok: response.ok,
    status: response.status,
    contentType,
    text,
    json,
    url,
    isHtml: looksLikeHtml(text, contentType)
  };
}

async function postChat(url, headers, payload) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
      signal: controller.signal
    });
    return await readUpstream(response, url);
  } finally {
    clearTimeout(timer);
  }
}

function shouldRetryWithoutJsonFormat(result) {
  const message = String(result?.json?.error?.message || result?.text || '').toLowerCase();
  return message.includes('response_format') ||
    message.includes('json_object') ||
    message.includes('not support') ||
    message.includes('unsupported');
}

function shouldRetryWithoutStream(result) {
  const message = String(result?.json?.error?.message || result?.text || '').toLowerCase();
  return message.includes('stream') &&
    (message.includes('not support') || message.includes('unsupported') || message.includes('invalid'));
}

function contentFromResult(result) {
  const data = result?.json;
  return data?.choices?.[0]?.message?.content ||
    data?.choices?.[0]?.text ||
    data?.output_text ||
    data?.text ||
    data?.content ||
    '';
}

function errorFromResult(result) {
  if (result?.isHtml) {
    return '上游返回 HTML，不是 JSON。请求地址：' + result.url +
      '；HTTP ' + result.status +
      '；Content-Type：' + (result.contentType || 'unknown') +
      '；HTML title：' + htmlTitle(result.text);
  }

  const upstreamMessage = result?.json?.error?.message || result?.json?.message || result?.text || 'Unknown upstream error';
  return '上游接口错误 ' + result.status + '：' + String(upstreamMessage).slice(0, 800) +
    '；请求地址：' + result.url;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') {
    res.status(405).json({ error: 'Method Not Allowed，请用 POST' });
    return;
  }

  try {
    let body = req.body;
    if (typeof body === 'string') {
      try { body = JSON.parse(body); } catch (_error) { body = {}; }
    }
    body = body || {};

    const {
      provider = 'openai',
      key,
      base,
      model = DEFAULT_MODEL,
      apiVersion = '2024-08-01-preview',
      system,
      user,
      wantJSON
    } = body;

    const apiKey = (key && key.trim()) || process.env.OPENAI_API_KEY;
    if (!apiKey) {
      res.status(400).json({
        error: '未配置 API Key：请用管理员入口配置，或在 Vercel 项目 Environment Variables 里设置 OPENAI_API_KEY。'
      });
      return;
    }

    const messages = [
      { role: 'system', content: system || '' },
      { role: 'user', content: user || '' }
    ];
    const payload = {
      model: model || DEFAULT_MODEL,
      temperature: wantJSON ? 0.3 : 0.7,
      max_tokens: wantJSON ? 3000 : 1400,
      messages
    };
    if (wantJSON) payload.response_format = { type: 'json_object' };

    let url;
    const headers = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': 'ai-shortdrama-studio-stepwise/1.0'
    };

    if (provider === 'azure') {
      const ep = ((base && base.trim()) || process.env.OPENAI_BASE_URL || '').replace(/\/+$/, '');
      if (!ep) {
        res.status(400).json({ error: 'Azure 模式需要填写 Endpoint，或在 Vercel 环境变量里设置 OPENAI_BASE_URL。' });
        return;
      }
      url = `${ep}/openai/deployments/${encodeURIComponent(model || DEFAULT_MODEL)}/chat/completions?api-version=${apiVersion}`;
      headers['api-key'] = apiKey;
      delete payload.model;
    } else {
      const configuredBase = (base && base.trim()) || process.env.OPENAI_BASE_URL || DEFAULT_BASE_URL;
      url = chatUrlFromBase(configuredBase);
      headers.Authorization = 'Bearer ' + apiKey;
      payload.stream = true;
    }

    let result = await postChat(url, headers, payload);

    if (!result.ok && provider !== 'azure' && shouldRetryWithoutStream(result)) {
      const retryPayload = { ...payload };
      delete retryPayload.stream;
      result = await postChat(url, headers, retryPayload);
    }

    if (!result.ok && wantJSON && shouldRetryWithoutJsonFormat(result)) {
      const retryPayload = { ...payload };
      delete retryPayload.response_format;
      result = await postChat(url, headers, retryPayload);
    }

    if (result.isHtml && provider !== 'azure') {
      const fallbackUrl = originV1ChatUrl(url);
      if (fallbackUrl && fallbackUrl !== url) {
        result = await postChat(fallbackUrl, headers, payload);
      }
    }

    if (!result.ok || result?.json?.error || result.isHtml) {
      res.status(result.status || 502).json({ error: errorFromResult(result) });
      return;
    }

    const content = contentFromResult(result);
    if (!content) {
      res.status(502).json({
        error: '上游返回成功但没有可读取文本。请求地址：' + result.url + '；响应：' + JSON.stringify(result.json || {}).slice(0, 800)
      });
      return;
    }

    res.status(200).json({ content });
  } catch (e) {
    const message = e?.name === 'AbortError'
      ? '请求上游接口超时（' + REQUEST_TIMEOUT_MS + 'ms）。'
      : String((e && e.message) || e);
    res.status(500).json({ error: message });
  }
};
