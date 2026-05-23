# shellcheck shell=bash

[[ -s "$HOME/src/karnov/jin/bin/jin" ]] && eval "$($HOME/src/karnov/jin/bin/jin init -)"


#alias kk="K=$(cdk && pwd);echo $K;"
# function _kgProjects(){
#   echo "stackedit amp content-store metadata-store missing-link xml-toolbox gitifier kg-site kg-site-assets kg-pipeline"
# }
# alias karnovUpdate="C=$(pwd);cdk; pwd; for f in $(_kgProjects); do cd \$f; pwd; git fetch; cd -; done;cd \$C"

alias j='jinborov'


alias cdk='cd ~/src/karnov'

# aliases for quick lint/transform via xml lib standard methods
export XML_CATALOG_PRJ="$HOME/src/karnov/ns-karnovgroup-com"
export XML_CATALOG_KAR="$HOME/src/karnov/ns-karnovgroup-com/ns.karnovgroup.com/catalog-entities-only-utf-8.xml"
export XML_CATALOG_FILES="$HOME/src/karnov/ns-karnovgroup-com/ns.karnovgroup.com/catalog-entities-only-utf-8.xml"
export XML_CATALOG_ILSE="$HOME/src/karnov/ns-karnovgroup-com/ns.karnovgroup.com/catalog-ilse-variant-utf-8.xml"
export XML_CATALOG_STRICT="$HOME/src/karnov/ns-karnovgroup-com/ns.karnovgroup.com/catalog-utf-8.xml"
# default for all lib-xml, set default XML_CATALOG_FILES env variable:
export XML_CATALOG_FILES="$XML_CATALOG_KAR"

alias karnov-catalog-ilse='XML_CATALOG_FILES=xmlcatalog $XML_CATALOG_ILSE'
alias karnov-catalog-strict='XML_CATALOG_FILES=xmlcatalog $XML_CATALOG_STRICT'
alias karnov-doctype='tmp_func(){ XML_CATALOG_FILES=$XML_CATALOG_KAR xmllint --dtdattr --noent --nonet --encode UTF-8 --format "$@" | grep -m 1 "<!DOCTYPE ";  unset -f tmp_func; }; tmp_func'
alias karnov-dtd-ilse='XML_CATALOG_FILES=$XML_CATALOG_ILSE xmllint --valid --noent --nonet --noout'
alias karnov-dtd-strict='XML_CATALOG_FILES=$XML_CATALOG_STRICT xmllint --valid --noent --nonet --noout'
alias karnov-root='XML_CATALOG_FILES=$XML_CATALOG_KAR xmllint --dtdattr --noent --nonet --xpath '\''name(/*)'\'''
alias karnov-utf-8='XML_CATALOG_FILES=$XML_CATALOG_KAR xmllint --dtdattr --noent --nonet --encode UTF-8'
alias karnov-xpath='XML_CATALOG_FILES=$XML_CATALOG_KAR xmllint --dtdattr --noent --nonet --xpath'
alias karnov-xslt1='XML_CATALOG_FILES=$XML_CATALOG_ILSE xsltproc --nonet'
