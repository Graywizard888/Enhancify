#!/data/data/com.termux/files/usr/bin/bash

TOKEN_DIR="$HOME/Enhancify"
TOKEN_FILE="$TOKEN_DIR/github_token.json"

verify_token() {
    local token="$1"
    
    notify info "Verifying Credentials"
    
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $token" \
        https://api.github.com/user 2>/dev/null)
    
    if [ "$response" = "200" ]; then
        return 0
    else
        return 1
    fi
}

add_keystore() {
    token=$(dialog --title "| Add Custom Token |" \
        --ok-label "Import" \
        --cancel-label "Cancel" \
        --inputbox "Enter your GitHub Token (Classic):" -1 -1 \
        3>&1 1>&2 2>&3)
    
    result=$?
    
    if [ $result -ne 0 ] || [ -z "$token" ]; then
        return
    fi
    
    if verify_token "$token"; then
        notify info "Verification Successful\nImporting..."
        
        mkdir -p "$TOKEN_DIR"
        
        echo "{}" | jq --arg token "$token" '.token = $token' > "$TOKEN_FILE"
        
        if [ $? -eq 0 ]; then
            notify msg "Github (Classic) Token Imported Successfully!"
        else
            notify msg "Failed to import Github (Classic) token"
        fi
    else
        notify msg "Verification Failed\nEntered Token Credentials May Invalid"
        return 1
    fi
}

delete_keystore() {
    dialog --backtitle 'Enhancify' --defaultno \
        --yesno "Are you sure to remove token from entry\nThis will cause to hit rate limit more often" 12 45
    
    result=$?
    
    if [ $result -eq 0 ]; then
        notify info "Removing Github (Clsssic) Token Entry"
        
        if [ -f "$TOKEN_FILE" ]; then
            rm -f "$TOKEN_FILE"
            
            if [ $? -eq 0 ]; then
                notify msg " Github (Classic) Token Removed Sucessfully"
                return 0
            else
                notify msg "Failed to remove Github (Classic) Token"
                return 1
            fi
        else
            notify msg "No Github (Classic) Token Detected In System"
            return 1
        fi
    fi
}

show_description() {
    description="HOW TO IMPORT GITHUB TOKEN (CLASSIC)

STEP-BY-STEP GUIDE:

1. Go to GitHub.com and login to your account

2. Click on your profile picture (top right corner)
   and select 'Settings'

3. Scroll down to the bottom and click 
   'Developer settings' (left sidebar)

4. Click 'Personal access tokens' → 'Tokens (classic)'

5. Click 'Generate new token' → 
   'Generate new token (classic)'

6. Give your token a descriptive name
   (e.g., 'Termux API Access')

7. Set expiration:
   - Recommended: 90 days
   - Or select 'No expiration' (less secure)

8. Select scopes (permissions):
   - Minimum: 'public_repo' for public repositories
   - Recommended: 'repo' for full repository access

9. Click 'Generate token' at the bottom

10. IMPORTANT: Copy the token immediately!
    You won't be able to see it again after leaving
    the page

11. Return to Enhancify and paste the token
    when prompted

BENEFITS:
• Increased API rate limit (5000/hour vs 60/hour)
• Access to private repositories (if scope selected)
• Better performance for GitHub operations
• Avoid rate limiting errors

NOTE:
• Token is stored securely in github_token.json
• Token can be removed anytime from this menu"
    
    dialog --title "| Description |" \
        --ok-label "Understood" \
        --msgbox "$description" -1 -1
}

custom_token() {
    while true; do
        MAIN_CHOICE=$("${DIALOG[@]}" \
            --title '| Custom Github Token Management |' \
            --cancel-label 'Back' \
            --ok-label 'Select' \
            --menu "Choose an option:" -1 -1 -1 \
            "Add Custom Token" "Add New Token" \
            "Delete Custom Token" "Delete Imported Token" \
            "Description" "How To Import Token" \
            2>&1 > /dev/tty)

        case $MAIN_CHOICE in
            "Add Custom Token")
                add_keystore
                ;;
            "Delete Custom Token")
                delete_keystore
                ;;
            "Description")
                show_description
                ;;
            *)
                break
                ;;
        esac
    done
}
