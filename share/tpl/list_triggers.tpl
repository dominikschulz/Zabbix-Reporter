<html>
    <head>
        <meta charset="utf-8" />
        <link rel="stylesheet" type="text/css" href="css/default.css" media="all" />
        <meta http-equiv="refresh" content="30" />
    </head>
    <body>
        [% FOREACH trigger IN triggers %]
        <div class="trigger [% trigger.severity %]">
            <div class="field severity">[% trigger.severity %]</div>
            <div class="field icon">
                [% IF trigger.acked %]
                <embed src="img/checkbox_yes.svg" type="image/svg+xml" width="20" height="20" />
                [% ELSE %]
                <embed src="img/checkbox_no.svg" type="image/svg+xml" width="20" height="20" />
                [% END %]
            </div>
            <div class="field host">[% trigger.host %]</div>
            <div class="field name">[% trigger.name %]</div>
            <div class="field time">since [% trigger.lastchange | localtime %]</div>
            <div class="field button"><!-- placeholder for details button --></div>
            <div class="clear"></div>
            <div class="details">[% trigger.description %]</div>
        </div>
        [% END %]
    </body>
</html>