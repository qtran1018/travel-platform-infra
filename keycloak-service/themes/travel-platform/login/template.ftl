<#import "field.ftl" as field>
<#import "footer.ftl" as loginFooter>

<#macro username>
  <#assign label>
    <#if !realm.loginWithEmailAllowed>${msg("username")}<#elseif !realm.registrationEmailAsUsername>${msg("usernameOrEmail")}<#else>${msg("email")}</#if>
  </#assign>
  <@field.group name="username" label=label>
    <div class="${properties.kcInputGroup}">
      <div class="${properties.kcInputGroupItemClass} ${properties.kcFill}">
        <span class="${properties.kcInputClass} ${properties.kcFormReadOnlyClass}">
          <input id="kc-attempted-username" value="${auth.attemptedUsername}" readonly>
        </span>
      </div>
      <div class="${properties.kcInputGroupItemClass}">
        <button id="reset-login" class="${properties.kcFormPasswordVisibilityButtonClass} kc-login-tooltip" type="button"
              aria-label="${msg('restartLoginTooltip')}" onclick="location.href='${url.loginRestartFlowUrl}'">
            <i class="fa-sync-alt fas" aria-hidden="true"></i>
            <span class="kc-tooltip-text">${msg("restartLoginTooltip")}</span>
        </button>
      </div>
    </@field.group>
</#macro>

<#macro registrationLayout bodyClass="" displayInfo=false displayMessage=true displayRequiredFields=false>
<!DOCTYPE html>
<html class="${properties.kcHtmlClass!}"<#if realm.internationalizationEnabled> lang="${locale.currentLanguageTag}" dir="${(locale.rtl)?then('rtl','ltr')}"</#if>>
<head>
  <meta charset="utf-8">
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
  <meta name="robots" content="noindex, nofollow">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <#if properties.meta?has_content>
    <#list properties.meta?split(' ') as meta>
      <meta name="${meta?split('==')[0]}" content="${meta?split('==')[1]}"/>
    </#list>
  </#if>
  <title>${msg("loginTitle",(realm.displayName!''))}</title>
  <link rel="icon" type="image/svg+xml" href="${url.resourcesPath}/img/favicon.svg" />
  <#if properties.stylesCommon?has_content>
    <#list properties.stylesCommon?split(' ') as style>
      <link href="${url.resourcesCommonPath}/${style}" rel="stylesheet" />
    </#list>
  </#if>
  <#if properties.styles?has_content>
    <#list properties.styles?split(' ') as style>
      <link href="${url.resourcesPath}/${style}" rel="stylesheet" />
    </#list>
  </#if>
  <link href="${url.resourcesPath}/css/login.css" rel="stylesheet" />
  <!-- Apply saved theme before paint to prevent flash -->
  <script>
    (function() {
      var s = localStorage.getItem('tp-theme');
      var sys = window.matchMedia('(prefers-color-scheme: dark)').matches;
      if (s === 'dark' || (!s && sys)) document.documentElement.classList.add('pf-v5-theme-dark');
    })();
  </script>
  <script type="importmap">{"imports":{"rfc4648":"${url.resourcesCommonPath}/vendor/rfc4648/rfc4648.js"}}</script>
  <#if properties.scripts?has_content>
    <#list properties.scripts?split(' ') as script>
      <script src="${url.resourcesPath}/${script}" type="text/javascript"></script>
    </#list>
  </#if>
  <#if scripts??><#list scripts as script><script src="${script}" type="text/javascript"></script></#list></#if>
  <script type="module" src="${url.resourcesPath}/js/passwordVisibility.js"></script>
  <script type="module">
    import { startSessionPolling } from "${url.resourcesPath}/js/authChecker.js";
    startSessionPolling("${url.ssoLoginInOtherTabsUrl?no_esc}");
  </script>
</head>

<body id="keycloak-bg">

<!-- Theme toggle (fixed top-right, all screen sizes) -->
<button class="tp-theme-toggle" id="tp-theme-toggle" aria-label="Toggle light/dark mode" onclick="(function(){var d=document.documentElement.classList.toggle('pf-v5-theme-dark');localStorage.setItem('tp-theme',d?'dark':'light');})()">
  <svg class="tp-icon-moon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <path d="M21 12.79A9 9 0 1111.21 3a7 7 0 009.79 9.79z"/>
  </svg>
  <svg class="tp-icon-sun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    <circle cx="12" cy="12" r="5"/><line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/>
    <line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/>
    <line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/>
    <line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>
  </svg>
</button>

<!-- Mobile-only brand bar -->
<div class="tp-mobile-bar">
  <span class="tp-mobile-brand-icon">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M17.8 19.2L16 11l3.5-3.5C21 6 21 4 19.5 2.5S18 2 16.5 3.5L13 7 4.8 5.2C4.3 5.1 3.8 5.4 3.6 5.8l-.8 1.5c-.2.5 0 1.1.4 1.4L9 11 6.5 13.5 4 13l-1.5 1.5 3 3 3 3L11 19l-.5-2.5L13 14l3.3 5.8c.3.5.9.7 1.4.4l1.5-.8c.4-.2.7-.7.6-1.2z"/>
    </svg>
  </span>
  <span class="tp-mobile-brand-name">Travel Platform</span>
</div>

<div class="tp-layout">

  <!-- ── Left: hero panel ──────────────────────────────────── -->
  <div class="tp-hero" aria-hidden="true">
    <div class="tp-hero-bg-dots"></div>
    <div class="tp-hero-glow"></div>
    <div class="tp-hero-inner">

      <div class="tp-brand">
        <span class="tp-brand-icon">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
            <path d="M17.8 19.2L16 11l3.5-3.5C21 6 21 4 19.5 2.5S18 2 16.5 3.5L13 7 4.8 5.2C4.3 5.1 3.8 5.4 3.6 5.8l-.8 1.5c-.2.5 0 1.1.4 1.4L9 11 6.5 13.5 4 13l-1.5 1.5 3 3 3 3L11 19l-.5-2.5L13 14l3.3 5.8c.3.5.9.7 1.4.4l1.5-.8c.4-.2.7-.7.6-1.2z"/>
          </svg>
        </span>
        <span class="tp-brand-name">Travel Platform</span>
      </div>

      <div class="tp-hero-body">
        <h2 class="tp-hero-title">Your next adventure<br>starts here.</h2>
        <p class="tp-hero-sub">Plan trips, split expenses, and explore the world — all in one place.</p>
        <ul class="tp-features">
          <li>
            <span class="tp-feat-icon">
              <svg viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M12 1.586l-4 4v12.828l4-4V1.586zM3.707 3.293A1 1 0 002 4v10a1 1 0 00.293.707L6 18.414V5.586L3.707 3.293zM17.707 5.293L14 1.586v12.828l2.293 2.293A1 1 0 0018 16V6a1 1 0 00-.293-.707z" clip-rule="evenodd"/></svg>
            </span>
            AI-powered itinerary planning
          </li>
          <li>
            <span class="tp-feat-icon">
              <svg viewBox="0 0 20 20" fill="currentColor"><path d="M8.433 7.418c.155-.103.346-.196.567-.267v1.698a2.305 2.305 0 01-.567-.267C8.07 8.34 8 8.114 8 8c0-.114.07-.34.433-.582zM11 12.849v-1.698c.22.071.412.164.567.267.364.243.433.468.433.582 0 .114-.07.34-.433.582a2.305 2.305 0 01-.567.267z"/><path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm1-13a1 1 0 10-2 0v.092a4.535 4.535 0 00-1.676.662C6.602 6.234 6 7.009 6 8c0 .99.602 1.765 1.324 2.246.48.32 1.054.545 1.676.662v1.941c-.391-.127-.68-.317-.843-.504a1 1 0 10-1.51 1.31c.562.649 1.413 1.076 2.353 1.253V15a1 1 0 102 0v-.092a4.535 4.535 0 001.676-.662C13.398 13.766 14 12.991 14 12c0-.99-.602-1.765-1.324-2.246A4.535 4.535 0 0011 9.092V7.151c.391.127.68.317.843.504a1 1 0 101.511-1.31c-.563-.649-1.413-1.076-2.354-1.253V5z" clip-rule="evenodd"/></svg>
            </span>
            Smart group expense splitting
          </li>
          <li>
            <span class="tp-feat-icon">
              <svg viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M5.05 4.05a7 7 0 119.9 9.9L10 18.9l-4.95-4.95a7 7 0 010-9.9zM10 11a2 2 0 100-4 2 2 0 000 4z" clip-rule="evenodd"/></svg>
            </span>
            Collaborative destination boards
          </li>
        </ul>
      </div>

      <div class="tp-hero-deco" aria-hidden="true">
        <svg viewBox="0 0 400 300" fill="none" xmlns="http://www.w3.org/2000/svg">
          <circle cx="200" cy="150" r="120" stroke="rgba(79,127,255,0.10)" stroke-width="1"/>
          <circle cx="200" cy="150" r="80" stroke="rgba(79,127,255,0.07)" stroke-width="1"/>
          <circle cx="200" cy="150" r="40" stroke="rgba(79,127,255,0.05)" stroke-width="1"/>
          <path d="M 80 150 Q 140 80 200 150 Q 260 220 320 150" stroke="rgba(79,127,255,0.18)" stroke-width="1.5" stroke-dasharray="4 4"/>
          <path d="M 60 200 Q 150 100 300 120" stroke="rgba(79,127,255,0.10)" stroke-width="1" stroke-dasharray="3 6"/>
          <circle cx="80" cy="150" r="3" fill="rgba(79,127,255,0.4)"/>
          <circle cx="200" cy="150" r="3" fill="rgba(79,127,255,0.4)"/>
          <circle cx="320" cy="150" r="3" fill="rgba(79,127,255,0.4)"/>
          <circle cx="300" cy="120" r="2" fill="rgba(79,127,255,0.3)"/>
          <circle cx="140" cy="95" r="2" fill="rgba(79,127,255,0.25)"/>
        </svg>
      </div>

    </div>
  </div>

  <!-- ── Right: form panel ──────────────────────────────────── -->
  <div class="tp-form-panel">
    <div class="tp-form-inner">

      <#-- Language selector -->
      <#if realm.internationalizationEnabled && locale.supported?size gt 1>
        <div class="tp-lang-select">
          <select aria-label="${msg("languages")}" onchange="if(this.value) window.location.href=this.value">
            <#list locale.supported?sort_by("label") as l>
              <option value="${l.url}" ${(l.languageTag == locale.currentLanguageTag)?then('selected','')}>${l.label}</option>
            </#list>
          </select>
        </div>
      </#if>

      <#-- Re-login: locked username banner -->
      <#if auth?has_content && auth.showUsername() && !auth.showResetCredentials()>
        <div class="tp-username-locked">
          <#if displayRequiredFields>
            <div class="tp-form-inner">
              <#nested "show-username">
              <@username />
            </div>
          <#else>
            <#nested "show-username">
            <@username />
          </#if>
        </div>
      </#if>

      <#-- Alert -->
      <#if displayMessage && message?has_content && (message.type != 'warning' || !isAppInitiatedAction??)>
        <div class="tp-alert tp-alert--${(message.type = 'error')?then('error', message.type)}">
          ${kcSanitize(message.summary)?no_esc}
        </div>
      </#if>

      <#-- Title -->
      <h1 class="tp-form-title"><#nested "header"></h1>

      <#-- Required fields note -->
      <#if displayRequiredFields && !(auth?has_content && auth.showUsername() && !auth.showResetCredentials())>
        <p class="tp-required-note"><span class="tp-required-star">*</span> ${msg("requiredFields")}</p>
      </#if>

      <#-- Form body -->
      <#nested "form">

      <#-- Social providers (OAuth) -->
      <#if social?? && social.providers?? && social.providers?has_content>
        <div class="tp-social-wrap">
          <div class="tp-social-divider"><span>or</span></div>
          <#nested "socialProviders">
        </div>
      </#if>

      <#-- Info section (e.g. "Don't have an account?") -->
      <#if displayInfo>
        <div class="tp-form-footer">
          <#nested "info">
        </div>
      </#if>

    </div>
  </div>

</div>
</body>
</html>
</#macro>
