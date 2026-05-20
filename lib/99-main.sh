# ===== main =====
main() {
    require_root "$@"
    check_systemd
    check_deps
    if [[ -f "$META_FILE" ]]; then
        load_meta
        manage_menu
    else
        install_flow
    fi
}

main "$@"
