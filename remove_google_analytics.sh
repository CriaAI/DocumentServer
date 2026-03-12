#!/usr/bin/env bash
# ============================================================================
# remove_google_analytics.sh
#
# Remove todas as referências ao Google Analytics do OnlyOffice Document Server.
# Baseado no diagnóstico de segurança criaAI — 09/03/2026.
#
# Uso:
#   cd DocumentServer
#   chmod +x remove_google_analytics.sh
#   ./remove_google_analytics.sh
#
# O script é idempotente — pode ser executado múltiplas vezes com segurança.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB_APPS="${SCRIPT_DIR}/web-apps"
BACKUP_DIR="${SCRIPT_DIR}/.analytics-backup-$(date +%Y%m%d%H%M%S)"
CHANGED=0
ERRORS=0

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info()  { echo -e "${CYAN}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; ERRORS=$((ERRORS + 1)); }

backup_file() {
    local file="$1"
    local rel="${file#${SCRIPT_DIR}/}"
    local dest="${BACKUP_DIR}/${rel}"
    mkdir -p "$(dirname "$dest")"
    cp "$file" "$dest"
}

# ============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║   Remoção do Google Analytics — OnlyOffice Document Server     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

if [ ! -d "$WEB_APPS" ]; then
    log_error "Diretório web-apps não encontrado em: $WEB_APPS"
    log_error "Execute este script a partir do diretório raiz do DocumentServer."
    exit 1
fi

mkdir -p "$BACKUP_DIR"
log_info "Backup em: $BACKUP_DIR"
echo ""

# ============================================================================
# PASSO 1: Neutralizar Analytics.js (transformar em no-op)
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASSO 1: Neutralizar Analytics.js"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ANALYTICS_FILE="${WEB_APPS}/apps/common/Analytics.js"
if [ -f "$ANALYTICS_FILE" ]; then
    backup_file "$ANALYTICS_FILE"
    cat > "$ANALYTICS_FILE" << 'ANALYTICS_EOF'
/*
 * Analytics.js — NEUTRALIZADO (criaAI)
 *
 * Módulo original do Google Analytics removido por razões de segurança.
 * Este stub mantém a interface pública para evitar erros em runtime,
 * mas não executa nenhuma operação nem carrega scripts externos.
 */
if (window.Common === undefined)
    window.Common = {};

Common.component = Common.component || {};

Common.Analytics = Common.component.Analytics = new(function() {
    return {
        initialize: function() { /* no-op */ },
        trackEvent: function() { /* no-op */ }
    }
})();
ANALYTICS_EOF
    log_ok "Analytics.js neutralizado (stub no-op criado)"
    CHANGED=$((CHANGED + 1))
else
    log_warn "Analytics.js não encontrado — possivelmente já removido"
fi

echo ""

# ============================================================================
# PASSO 2: Remover 'analytics' dos paths do require.config nos app.js
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASSO 2: Limpar require.config paths nos app.js e app_dev.js"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

APP_FILES=(
    "${WEB_APPS}/apps/documenteditor/main/app.js"
    "${WEB_APPS}/apps/spreadsheeteditor/main/app.js"
    "${WEB_APPS}/apps/presentationeditor/main/app.js"
    "${WEB_APPS}/apps/pdfeditor/main/app.js"
    "${WEB_APPS}/apps/visioeditor/main/app.js"
    "${WEB_APPS}/apps/documenteditor/forms/app.js"
    "${WEB_APPS}/apps/documenteditor/main/app_dev.js"
    "${WEB_APPS}/apps/spreadsheeteditor/main/app_dev.js"
    "${WEB_APPS}/apps/presentationeditor/main/app_dev.js"
    "${WEB_APPS}/apps/pdfeditor/main/app_dev.js"
    "${WEB_APPS}/apps/visioeditor/main/app_dev.js"
    "${WEB_APPS}/apps/documenteditor/forms/app_dev.js"
)

for file in "${APP_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        log_warn "Arquivo não encontrado: ${file#${SCRIPT_DIR}/}"
        continue
    fi

    backup_file "$file"
    local_changed=0

    # Remover a linha "analytics : 'common/Analytics'," do bloco paths
    if grep -q "analytics.*:.*'common/Analytics'" "$file"; then
        sed -i "/analytics.*:.*'common\/Analytics'/d" "$file"
        local_changed=1
    fi

    # Remover o bloco shim inteiro para analytics (pode ter 3-5 linhas)
    if grep -q "analytics:" "$file"; then
        # Remove o bloco: analytics: { deps: [ 'jquery' ] }
        # Usando perl para lidar com blocos multi-linha
        perl -i -0pe 's/,?\s*analytics\s*:\s*\{[^}]*\}//gs' "$file"
        # Limpar possível vírgula dupla ou trailing comma antes de }
        perl -i -0pe 's/,(\s*\})/$1/gs' "$file"
        local_changed=1
    fi

    # Remover 'analytics' da lista de dependências do require([...])
    if grep -q "'analytics'" "$file"; then
        sed -i "/'analytics',/d" "$file"
        sed -i "/'analytics'/d" "$file"
        local_changed=1
    fi

    if [ $local_changed -eq 1 ]; then
        log_ok "Limpo: ${file#${SCRIPT_DIR}/}"
        CHANGED=$((CHANGED + 1))
    else
        log_info "Sem alterações necessárias: ${file#${SCRIPT_DIR}/}"
    fi
done

echo ""

# ============================================================================
# PASSO 3: Remover chamadas Common.Analytics.trackEvent nos embed controllers
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASSO 3: Remover chamadas trackEvent nos embed controllers"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

EMBED_CONTROLLERS=(
    "${WEB_APPS}/apps/documenteditor/embed/js/ApplicationController.js"
    "${WEB_APPS}/apps/spreadsheeteditor/embed/js/ApplicationController.js"
    "${WEB_APPS}/apps/presentationeditor/embed/js/ApplicationController.js"
    "${WEB_APPS}/apps/visioeditor/embed/js/ApplicationController.js"
    "${WEB_APPS}/apps/documenteditor/forms/app/controller/ApplicationController.js"
)

for file in "${EMBED_CONTROLLERS[@]}"; do
    if [ ! -f "$file" ]; then
        log_warn "Arquivo não encontrado: ${file#${SCRIPT_DIR}/}"
        continue
    fi

    backup_file "$file"
    local_changed=0

    # Remover linhas com Common.Analytics.initialize (comentadas ou não)
    if grep -q "Common\.Analytics\.initialize" "$file"; then
        sed -i '/Common\.Analytics\.initialize/d' "$file"
        local_changed=1
    fi

    # Remover linhas com Common.Analytics.trackEvent
    if grep -q "Common\.Analytics\.trackEvent" "$file"; then
        sed -i '/Common\.Analytics\.trackEvent/d' "$file"
        local_changed=1
    fi

    # Remover bloco de comentário "Initialize analytics" que ficou órfão
    if grep -q "Initialize analytics" "$file"; then
        sed -i '/\/\/ Initialize analytics/d' "$file"
        sed -i '/\/\/ -------------------------/{N;/^\s*$/d;}' "$file"
        local_changed=1
    fi

    if [ $local_changed -eq 1 ]; then
        log_ok "Limpo: ${file#${SCRIPT_DIR}/}"
        CHANGED=$((CHANGED + 1))
    else
        log_info "Sem alterações necessárias: ${file#${SCRIPT_DIR}/}"
    fi
done

echo ""

# ============================================================================
# PASSO 4: Remover <script> tags do Analytics.js nos HTML de embed
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASSO 4: Remover script tags do Analytics.js nos HTML de embed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

EMBED_HTML_FILES=(
    "${WEB_APPS}/apps/documenteditor/embed/index.html"
    "${WEB_APPS}/apps/documenteditor/embed/index_loader.html"
    "${WEB_APPS}/apps/spreadsheeteditor/embed/index.html"
    "${WEB_APPS}/apps/spreadsheeteditor/embed/index_loader.html"
    "${WEB_APPS}/apps/presentationeditor/embed/index.html"
    "${WEB_APPS}/apps/presentationeditor/embed/index_loader.html"
    "${WEB_APPS}/apps/visioeditor/embed/index.html"
    "${WEB_APPS}/apps/visioeditor/embed/index_loader.html"
)

for file in "${EMBED_HTML_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        log_warn "Arquivo não encontrado: ${file#${SCRIPT_DIR}/}"
        continue
    fi

    backup_file "$file"

    if grep -q "Analytics.js" "$file"; then
        sed -i '/Analytics\.js/d' "$file"
        log_ok "Limpo: ${file#${SCRIPT_DIR}/}"
        CHANGED=$((CHANGED + 1))
    else
        log_info "Sem alterações necessárias: ${file#${SCRIPT_DIR}/}"
    fi
done

echo ""

# ============================================================================
# PASSO 5: Limpar referências nos build JSON configs
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASSO 5: Limpar referências nos build JSON configs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

BUILD_JSON_FILES=(
    "${WEB_APPS}/build/documenteditor.json"
    "${WEB_APPS}/build/spreadsheeteditor.json"
    "${WEB_APPS}/build/presentationeditor.json"
    "${WEB_APPS}/build/pdfeditor.json"
    "${WEB_APPS}/build/visioeditor.json"
    "${WEB_APPS}/build/appforms.json"
)

for file in "${BUILD_JSON_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        log_warn "Arquivo não encontrado: ${file#${SCRIPT_DIR}/}"
        continue
    fi

    backup_file "$file"
    local_changed=0

    # Remover a linha do path: "analytics": "common/Analytics",
    if grep -q '"analytics".*"common/Analytics"' "$file"; then
        sed -i '/"analytics".*"common\/Analytics"/d' "$file"
        local_changed=1
    fi

    # Remover o bloco shim analytics (multi-linha)
    if grep -q '"analytics"' "$file"; then
        # Usar perl para remover o bloco JSON: "analytics": { "deps": [...] },
        perl -i -0pe 's/,?\s*"analytics"\s*:\s*\{[^}]*\}//gs' "$file"
        # Limpar vírgulas órfãs
        perl -i -0pe 's/,(\s*[}\]])/$1/gs' "$file"
        local_changed=1
    fi

    # Remover a inclusão do arquivo Analytics.js da lista de includes
    if grep -q 'Analytics\.js' "$file"; then
        # Remover a linha e a vírgula da linha anterior se necessário
        sed -i '/Analytics\.js/d' "$file"
        local_changed=1
    fi

    if [ $local_changed -eq 1 ]; then
        log_ok "Limpo: ${file#${SCRIPT_DIR}/}"
        CHANGED=$((CHANGED + 1))
    else
        log_info "Sem alterações necessárias: ${file#${SCRIPT_DIR}/}"
    fi
done

echo ""

# ============================================================================
# PASSO 6: Verificação
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  PASSO 6: Verificação pós-remoção"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Verificar se ainda existem referências ativas ao GA
REMAINING=$(grep -r --include="*.js" --include="*.html" --include="*.json" \
    -l "google-analytics\|_gaq\|UA-12442749" \
    "$WEB_APPS" 2>/dev/null | grep -v "node_modules" | grep -v ".analytics-backup" || true)

if [ -n "$REMAINING" ]; then
    log_warn "Referências residuais ao Google Analytics encontradas em:"
    echo "$REMAINING" | while read -r f; do
        echo "    → ${f#${SCRIPT_DIR}/}"
    done
else
    log_ok "Nenhuma referência ao Google Analytics (google-analytics, _gaq, UA-12442749) encontrada"
fi

# Verificar se Common.Analytics.trackEvent ainda é chamado em algum lugar
# (excluindo o stub)
REMAINING_CALLS=$(grep -r --include="*.js" --include="*.jsx" \
    "Common\.Analytics\.trackEvent\|Common\.Analytics\.initialize" \
    "$WEB_APPS" 2>/dev/null \
    | grep -v "node_modules" \
    | grep -v ".analytics-backup" \
    | grep -v "no-op" \
    | grep -v "^.*Analytics\.js:" || true)

if [ -n "$REMAINING_CALLS" ]; then
    log_warn "Chamadas residuais a Common.Analytics encontradas:"
    echo "$REMAINING_CALLS" | while read -r line; do
        echo "    → $line"
    done
    echo ""
    log_info "Estas chamadas são inofensivas pois o stub no-op absorve as chamadas."
    log_info "Para limpeza completa, remova-as manualmente."
else
    log_ok "Nenhuma chamada ativa a Common.Analytics.trackEvent/initialize encontrada"
fi

echo ""

# ============================================================================
# RESUMO
# ============================================================================
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                         RESUMO                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  Arquivos alterados: ${GREEN}${CHANGED}${NC}"
echo -e "  Erros:              ${RED}${ERRORS}${NC}"
echo -e "  Backup em:          ${CYAN}${BACKUP_DIR}${NC}"
echo ""

if [ $ERRORS -eq 0 ]; then
    log_ok "Google Analytics removido com sucesso do Document Server."
    echo ""
    echo "  Próximos passos:"
    echo "    1. Reconstruir os editores (grunt build)"
    echo "    2. Reconstruir a imagem Docker"
    echo "    3. Verificar no navegador (DevTools → Network) que nenhuma"
    echo "       requisição sai para .google-analytics.com"
    echo ""
    echo "  Para reverter:"
    echo "    cp -r ${BACKUP_DIR}/* ${SCRIPT_DIR}/"
    echo ""
else
    log_error "Concluído com ${ERRORS} erro(s). Revise os avisos acima."
fi
